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
        panel.animationBehavior = .none
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.setContentSize(panelSize)
    }

    deinit {
        stopMonitoring()
    }

    var isShown: Bool {
        panel.isVisible && !isClosing && panel.alphaValue > 0
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
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        prepareAnchor(button)

        if applyPlacement(relativeTo: button, reveal: false) {
            panel.orderFrontRegardless()
            schedulePresentation(relativeTo: button)
            return
        }

        schedulePresentation(relativeTo: button)
    }

    func close() {
        guard panel.isVisible, !isClosing else { return }
        isClosing = true
        stopMonitoring()
        panel.orderOut(nil)
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        isClosing = false
    }

    func updatePanelSize(_ newSize: NSSize) {
        guard newSize != preferredPanelSize else { return }
        preferredPanelSize = newSize
        guard isShown, let anchorButton else { return }
        _ = applyPlacement(relativeTo: anchorButton, reveal: false)
    }

    private func schedulePresentation(relativeTo button: NSStatusBarButton) {
        DispatchQueue.main.async { [weak self, weak button] in
            guard let self, let button, self.anchorButton === button, !self.isClosing else {
                return
            }

            self.prepareAnchor(button)
            _ = self.applyPlacement(relativeTo: button, reveal: true)
        }
    }

    private func applyPlacement(relativeTo button: NSStatusBarButton, reveal: Bool) -> Bool {
        guard let placement = targetPlacement(relativeTo: button) else { return false }
        apply(placement)
        if reveal {
            revealPanel()
        }
        return true
    }

    private func apply(_ placement: MenuPanelPlacement) {
        contentController.updatePresentation(
            designSize: placement.designSize,
            scale: placement.scale
        )

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        if panel.frame != placement.frame {
            panel.setFrame(placement.frame, display: true)
        }
        NSAnimationContext.endGrouping()
        panel.invalidateShadow()
    }

    private func revealPanel() {
        panel.ignoresMouseEvents = false
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        startMonitoring()
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

    private func targetPlacement(relativeTo button: NSStatusBarButton) -> MenuPanelPlacement? {
        guard let buttonFrame = screenRect(for: button) else { return nil }

        // The status-item window owns the authoritative screen assignment. A
        // center-point lookup across NSScreen.screens can select an adjacent
        // display while the menu bar is moving or its button is being laid out.
        guard let screen = button.window?.screen
            ?? screenContaining(point: NSPoint(x: buttonFrame.midX, y: buttonFrame.midY))
            ?? NSScreen.screens.first(where: { $0.frame.intersects(buttonFrame) }),
            !screen.visibleFrame.isEmpty else {
            return nil
        }

        guard MenuPanelLayout.isStableMenuBarAnchor(
            buttonFrame,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        ) else {
            return nil
        }

        return MenuPanelLayout.placement(
            preferredSize: preferredPanelSize,
            anchorFrame: buttonFrame,
            visibleFrame: screen.visibleFrame
        )
    }

    private func screenContaining(point: NSPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(point) })
    }

    private func prepareAnchor(_ button: NSStatusBarButton) {
        button.window?.layoutIfNeeded()
        button.layoutSubtreeIfNeeded()
    }

    private func screenRect(for button: NSStatusBarButton) -> NSRect? {
        guard let window = button.window else { return nil }
        let windowFrame = window.frame
        if windowFrame.width > 0, windowFrame.height > 0 {
            return windowFrame
        }

        let rectInWindow = button.convert(button.bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        guard screenRect.width > 0, screenRect.height > 0 else { return nil }
        return screenRect
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
