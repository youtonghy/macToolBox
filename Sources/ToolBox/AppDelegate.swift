import AppKit
import SwiftUI
import Combine
import OSLog

@MainActor
final class TerminationShutdownCoordinator {
    private let timeout: Duration
    private var didReply = false
    private var shutdownTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(timeout: Duration) {
        self.timeout = timeout
    }

    func start(
        shutdown: @escaping @MainActor () async -> Void,
        reply: @escaping @MainActor () -> Void
    ) {
        guard shutdownTask == nil, timeoutTask == nil, !didReply else { return }
        shutdownTask = Task { [weak self] in
            await shutdown()
            self?.finish(reply: reply)
        }
        timeoutTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.timeout)
            } catch {
                return
            }
            self.finish(reply: reply)
        }
    }

    private func finish(reply: @MainActor () -> Void) {
        guard !didReply else { return }
        didReply = true
        shutdownTask?.cancel()
        timeoutTask?.cancel()
        shutdownTask = nil
        timeoutTask = nil
        reply()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private lazy var menuBarPanelController = MenuBarPanelController(
        rootView: PopoverContent(
            state: state,
            hardware: hardware,
            displayControl: displayControlMenu,
            audioRouting: audioRouting,
            focusMode: focusMode,
            wifiSignal: wifiSignal
        ),
        panelSize: currentPanelSize
    )
    private var settingsWindowController: NSWindowController?
    private let state = FeatureState()
    private let hardware = HardwareMenuModel()
    private let displayControl = DisplayControlService.shared
    private let displayControlMenu = DisplayControlMenuModel()
    private let audioRouting = AudioRoutingService()
    private let wifiSignal = WiFiSignalModel()
    private let shortcutRegistry = ShortcutRegistry()
    private lazy var shortcutSettings = ShortcutSettingsModel(registry: shortcutRegistry)
    private let screenshotWindowProvider = WindowRegionProvider()
    private lazy var screenshotAXProvider = AXRegionProvider()
    private let screenshotPreview = ScreenshotPreviewController()
    private lazy var screenshotCoordinator = ScreenshotCoordinator(
        permission: ScreenCapturePermission(),
        captureProvider: ScreenCaptureProvider(),
        overlay: ScreenshotSelectionOverlayManager(),
        candidateResolver: { [weak self] point, generation in
            guard let self else { return [] }
            let defaults = UserDefaults.standard
            let key = "screenshot.smartElementCandidates"
            let smartCandidates = defaults.object(forKey: key) as? Bool ?? true
            let window = try? await self.screenshotWindowProvider.region(
                at: point,
                generation: generation
            )
            if smartCandidates, let window,
               let candidates = try? await self.screenshotAXProvider.regions(
                   at: point,
                   generation: generation,
                   targetWindow: window
               ) {
                return candidates
            }
            return window.map { [$0] } ?? []
        },
        windowCandidateResolver: { [weak self] point, generation in
            try? await self?.screenshotWindowProvider.region(at: point, generation: generation)
        },
        onSelectionSessionEnded: { [weak self] in
            // Leave target applications exactly as we found them: undo any
            // accessibility opt-in attributes we enabled during this session.
            self?.screenshotAXProvider.restoreActivatedApplications()
        },
        bringEditorForward: { [weak self] in self?.screenshotPreview.bringForward() },
        editorHandoff: { [weak self] image in self?.screenshotPreview.show(image: image) },
        documentHandoff: { [weak self] document, cleanup in
            self?.screenshotPreview.show(document: document, cleanup: cleanup)
        }
    )
    private let logger = Logger(subsystem: "ToolBox", category: "AppDelegate")
    private lazy var displayControlKeys = DisplayControlMediaKeyController(
        service: displayControl,
        menuModel: displayControlMenu,
        shortcutRegistry: shortcutRegistry
    )
    private lazy var brightnessSchedule = BrightnessScheduleCoordinator(
        service: displayControl
    )
    private let focusSystemObserver = SystemFocusModeObserver()
    private let focusOverlayManager = FocusOverlayManager()
    private lazy var focusMode = FocusModeCoordinator(
        systemObserver: focusSystemObserver,
        overlayManager: focusOverlayManager,
        screensProvider: FocusScreenProvider.currentScreens
    )
    private var cancellables = Set<AnyCancellable>()
    private var isTerminating = false
    private var terminationShutdownCoordinator: TerminationShutdownCoordinator?

    private var currentPanelSize: NSSize {
        MenuPanelLayout.panelSize(
            cableItemCount: hardware.cableItems.count,
            showsDisplayControl: displayControlMenu.hasExternalDisplay,
            showsAudioSection: !audioRouting.menuRows.isEmpty,
            showsColorPreset: displayControlMenu.presetAvailable,
            audioRowCount: audioRouting.menuRows.count
        )
    }

    // Feature coordinators.
    let screenWipe = ScreenWipeCoordinator()
    let awake = AwakeCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders with Info.plist LSUIElement.
        NSApp.setActivationPolicy(.accessory)
        screenshotPreview.onClose = { [weak self] in
            self?.screenshotCoordinator.previewClosed()
        }
        try? ScrollCaptureCleanup.removeStaleSessions()

        // Menu-bar status item.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "hammer", accessibilityDescription: "ToolBox")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Wire toggles -> coordinators.
        state.$wipeOn
            .dropFirst().removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.applyWipe(on) }
            .store(in: &cancellables)
        state.$awakeOn
            .dropFirst().removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.applyAwake(on) }
            .store(in: &cancellables)

        shortcutRegistry.onRoutedAction = { [weak self] action in
            self?.handleShortcutAction(action) ?? false
        }
        do {
            try shortcutRegistry.start(rules: shortcutSettings.rules)
        } catch {
            logger.error(
                "Failed to start shortcut registry: \(String(describing: error), privacy: .public)"
            )
        }

        hardware.start()
        displayControl.start()
        brightnessSchedule.start()
        displayControlMenu.start()
        displayControlKeys.start()
        audioRouting.start()
        wifiSignal.start()
        focusMode.start()
        observePanelSizeChanges()
        refreshPanelSize()
    }

    private func observePanelSizeChanges() {
        Publishers.CombineLatest4(
            hardware.$cableItems.map(\.count).removeDuplicates(),
            displayControlMenu.$displayItems.map { !$0.isEmpty }.removeDuplicates(),
            audioRouting.$menuRows.map(\.count).removeDuplicates(),
            displayControlMenu.$presetAvailable.removeDuplicates()
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.refreshPanelSize()
            }
            .store(in: &cancellables)
    }

    private func refreshPanelSize() {
        // Force lazy controller creation so the first open already uses the current layout.
        _ = menuBarPanelController
        menuBarPanelController.updatePanelSize(currentPanelSize)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        stopNonAudioServices()
        let coordinator = TerminationShutdownCoordinator(timeout: .seconds(2))
        terminationShutdownCoordinator = coordinator
        coordinator.start(
            shutdown: { [weak self] in
                _ = await self?.audioRouting.shutdown()
            },
            reply: {
                sender.reply(toApplicationShouldTerminate: true)
            }
        )
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        DevRuntimeLogCapture.shared.stop()
        guard !isTerminating else { return }
        stopNonAudioServices()
        audioRouting.stop()
    }

    private func stopNonAudioServices() {
        screenWipe.stop()
        screenshotCoordinator.cancel()
        screenshotPreview.close()
        displayControlKeys.stop()
        if let status = shortcutRegistry.stop() {
            logger.error("Shortcut registry cleanup incomplete: \(status, privacy: .public)")
        }
        awake.stop()
        focusMode.stop()
        hardware.stop()
        wifiSignal.stop()
        displayControlMenu.stop()
        brightnessSchedule.stop()
        displayControl.stop()
    }

    // MARK: - Status item / popover

    @objc private func handleStatusItemClick(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        guard let event = NSApp.currentEvent else {
            togglePopover(button)
            return
        }

        let isRightClick = event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
        if isRightClick {
            showStatusMenu(with: event, button: button)
        } else {
            togglePopover(button)
        }
    }

    private func togglePopover(_ sender: Any?) {
        if menuBarPanelController.isShown {
            menuBarPanelController.close()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        menuBarPanelController.show(relativeTo: button)
    }

    private func showStatusMenu(with event: NSEvent, button: NSStatusBarButton) {
        if menuBarPanelController.isShown {
            menuBarPanelController.close()
        }
        NSMenu.popUpContextMenu(makeStatusMenu(), with: event, for: button)
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(
            title: "打开面板",
            action: #selector(openMainPanel(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())

        let wipeItem = NSMenuItem(
            title: "擦屏幕",
            action: #selector(toggleWipeFromMenu(_:)),
            keyEquivalent: ""
        )
        wipeItem.state = state.wipeOn ? .on : .off
        menu.addItem(wipeItem)

        let awakeItem = NSMenuItem(
            title: "后台干",
            action: #selector(toggleAwakeFromMenu(_:)),
            keyEquivalent: ""
        )
        awakeItem.state = state.awakeOn ? .on : .off
        menu.addItem(awakeItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "设置",
            action: #selector(openSettingsWindow(_:)),
            keyEquivalent: ","
        ))
        menu.addItem(NSMenuItem(
            title: "退出",
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q"
        ))

        for item in menu.items {
            item.target = self
        }
        return menu
    }

    @objc private func openMainPanel(_ sender: Any?) {
        showPopover()
    }

    @objc private func toggleWipeFromMenu(_ sender: Any?) {
        state.wipeOn.toggle()
    }

    @objc private func toggleAwakeFromMenu(_ sender: Any?) {
        state.awakeOn.toggle()
    }

    @objc private func openSettingsWindow(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let controller = settingsWindowController ?? makeSettingsWindowController()
        settingsWindowController = controller
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
    }

    @objc private func quitApplication(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    private func makeSettingsWindowController() -> NSWindowController {
        let windowSize = NSSize(width: 840, height: 560)
        let hostingController = GlassHostingViewController(
            rootView: SettingsView(
                hardware: hardware,
                displayControl: displayControlMenu,
                shortcutRegistry: shortcutRegistry,
                brightnessSchedule: brightnessSchedule,
                audioRouting: audioRouting,
                focusMode: focusMode,
                wifiSignal: wifiSignal,
                shortcutSettings: shortcutSettings
            ),
            contentSize: windowSize,
            contentInsets: NSEdgeInsets(top: 52, left: 20, bottom: 20, right: 20)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "设置"
        window.setContentSize(windowSize)
        window.minSize = NSSize(width: 760, height: 500)
        window.styleMask.insert(.titled)
        window.styleMask.insert(.closable)
        window.styleMask.insert(.miniaturizable)
        window.styleMask.insert(.resizable)
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.toolbarStyle = .unifiedCompact
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()

        let controller = NSWindowController(window: window)
        controller.shouldCascadeWindows = true
        return controller
    }

    // MARK: - Feature wiring

    private func applyWipe(_ on: Bool) {
        if on {
            let started = screenWipe.start(
                exitShortcutAvailable: shortcutRegistry.isRegistered(.screenWipeExit)
            ) { [weak self] in
                // Auto-dismissed (timeout or shortcut) -> reflect in UI.
                DispatchQueue.main.async { self?.state.wipeOn = false }
            }
            if !started {
                DispatchQueue.main.async { [weak self] in self?.state.wipeOn = false }
            }
        } else {
            screenWipe.stop()
        }
    }

    private func applyAwake(_ on: Bool) {
        if on { awake.start() } else { awake.stop() }
    }

    private func handleShortcutAction(_ action: ShortcutAction) -> Bool {
        switch action {
        case .hotKey(.captureRegion):
            Task { [weak self] in await self?.screenshotCoordinator.startRegionCapture() }
            return true
        case .hotKey(.screenWipeExit):
            state.wipeOn = false
            screenWipe.stop()
            return true
        case .mediaKey(let event):
            return displayControlKeys.handle(event: event)
        }
    }
}
