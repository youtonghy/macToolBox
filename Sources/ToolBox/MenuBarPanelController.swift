import AppKit
import SwiftUI

enum MenuBarPanelConfiguration {
    static let contentInsets = MenuPanelLayout.contentInsets
}

final class MenuBarPanelController<Content: View>: NSObject {
    private var preferredPanelSize: NSSize
    private let contentController: GlassPopoverViewController<Content>
    private let panel: MenuBarPanel
    private weak var anchorButton: NSStatusBarButton?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isClosing = false

    init(rootView: Content, panelSize: NSSize) {
        self.preferredPanelSize = panelSize
        let contentController = GlassPopoverViewController(
            rootView: rootView,
            contentSize: panelSize,
            contentInsets: MenuBarPanelConfiguration.contentInsets
        )
        self.contentController = contentController
        self.panel = MenuBarPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init()

        panel.contentViewController = contentController
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .utilityWindow
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.setContentSize(panelSize)
    }

    deinit {
        stopMonitoring()
    }

    var isShown: Bool {
        panel.isVisible && !isClosing
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if isShown {
            close()
        } else {
            show(relativeTo: button)
        }
    }

    func show(relativeTo button: NSStatusBarButton) {
        anchorButton = button
        isClosing = false
        button.layoutSubtreeIfNeeded()

        guard showPositionedPanel(relativeTo: button) else {
            DispatchQueue.main.async { [weak self, weak button] in
                guard let self, let button, self.anchorButton === button, !self.panel.isVisible else {
                    return
                }
                button.layoutSubtreeIfNeeded()
                _ = self.showPositionedPanel(relativeTo: button)
            }
            return
        }
    }

    private func showPositionedPanel(relativeTo button: NSStatusBarButton) -> Bool {
        guard let frame = targetPanelFrame(relativeTo: button) else { return false }
        applyPanelFrame(frame)
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        startMonitoring()
        return true
    }

    func close() {
        guard panel.isVisible, !isClosing else { return }
        isClosing = true
        stopMonitoring()
        panel.orderOut(nil)
        panel.alphaValue = 1
        isClosing = false
    }

    func updatePanelSize(_ newSize: NSSize) {
        guard newSize != preferredPanelSize else { return }
        preferredPanelSize = newSize
        guard isShown, let anchorButton else { return }
        guard let frame = targetPanelFrame(relativeTo: anchorButton) else { return }
        applyPanelFrame(frame)
    }

    private func applyPanelFrame(_ frame: NSRect) {
        contentController.updateContentSize(frame.size)
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
        panel.setContentSize(frame.size)
        panel.invalidateShadow()
    }

    private func startMonitoring() {
        stopMonitoring()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            self?.handleMouseEvent(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.close()
                return nil
            }

            self.handleMouseEvent(event)
            return event
        }
    }

    private func stopMonitoring() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func handleMouseEvent(_ event: NSEvent) {
        let screenPoint = screenPoint(for: event)
        if panel.frame.contains(screenPoint) {
            return
        }

        if let buttonFrame = anchorButton.flatMap(screenRect(for:)), buttonFrame.contains(screenPoint) {
            return
        }

        close()
    }

    private func targetPanelFrame(relativeTo button: NSStatusBarButton) -> NSRect? {
        guard let buttonFrame = screenRect(for: button) else { return nil }
        let screens = NSScreen.screens.map {
            MenuPanelScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        return MenuPanelLayout.panelFrame(
            preferredSize: preferredPanelSize,
            anchorFrame: buttonFrame,
            screens: screens
        )
    }

    private func screenRect(for button: NSStatusBarButton) -> NSRect? {
        guard let window = button.window else { return nil }
        let rectInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(rectInWindow)
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        if let window = event.window {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        return NSEvent.mouseLocation
    }
}

private final class MenuBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
