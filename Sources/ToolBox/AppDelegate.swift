import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private lazy var menuBarPanelController = MenuBarPanelController(
        rootView: PopoverContent(state: state, hardware: hardware, displayControl: displayControlMenu),
        panelSize: currentPanelSize
    )
    private var settingsWindowController: NSWindowController?
    private let state = FeatureState()
    private let hardware = HardwareMenuModel()
    private let displayControl = DisplayControlService.shared
    private let displayControlMenu = DisplayControlMenuModel()
    private lazy var displayControlKeys = DisplayControlMediaKeyController(
        service: displayControl,
        menuModel: displayControlMenu
    )
    private lazy var brightnessSchedule = BrightnessScheduleCoordinator(
        service: displayControl
    )
    private var cancellables = Set<AnyCancellable>()

    private var currentPanelSize: NSSize {
        MenuPanelLayout.panelSize(
            cableItemCount: hardware.cableItems.count,
            showsDisplayControl: displayControlMenu.hasExternalDisplay
        )
    }

    // Feature coordinators.
    let screenWipe = ScreenWipeCoordinator()
    let awake = AwakeCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders with Info.plist LSUIElement.
        NSApp.setActivationPolicy(.accessory)

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

        hardware.start()
        displayControl.start()
        brightnessSchedule.start()
        displayControlMenu.start()
        displayControlKeys.start()
        observePanelSizeChanges()
        refreshPanelSize()
    }

    private func observePanelSizeChanges() {
        Publishers.CombineLatest(hardware.$cableItems, displayControlMenu.$displayItems)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.refreshPanelSize()
            }
            .store(in: &cancellables)
    }

    private func refreshPanelSize() {
        // Force lazy controller creation so the first open already uses the current layout.
        _ = menuBarPanelController
        menuBarPanelController.updatePanelSize(currentPanelSize)
    }

    func applicationWillTerminate(_ notification: Notification) {
        screenWipe.stop()
        awake.stop()
        hardware.stop()
        displayControlKeys.stop()
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
                mediaKeys: displayControlKeys,
                brightnessSchedule: brightnessSchedule
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
            screenWipe.start { [weak self] in
                // Auto-dismissed (timeout or long-press) -> reflect in UI.
                DispatchQueue.main.async { self?.state.wipeOn = false }
            }
        } else {
            screenWipe.stop()
        }
    }

    private func applyAwake(_ on: Bool) {
        if on { awake.start() } else { awake.stop() }
    }
}
