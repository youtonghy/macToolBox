import AppKit
import SwiftUI

enum MenuBarPanelConfiguration {
    static let contentInsets = MenuPanelLayout.contentInsets
}

final class MenuBarPanelController<Content: View>: NSObject {
    private var panelSize: NSSize
    private let contentController: GlassPopoverViewController<Content>
    private let panel: MenuBarPanel
    private weak var anchorButton: NSStatusBarButton?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isClosing = false

    init(rootView: Content, panelSize: NSSize) {
        self.panelSize = panelSize
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
        applyPanelSize(panelSize, reanchorIfVisible: false)
        panel.alphaValue = 1
        panel.setFrameOrigin(panelOrigin(relativeTo: button))
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        startMonitoring()
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
        applyPanelSize(newSize, reanchorIfVisible: true)
    }

    private func applyPanelSize(_ newSize: NSSize, reanchorIfVisible: Bool) {
        let sizeChanged = newSize != panelSize
        panelSize = newSize
        contentController.updateContentSize(newSize)

        if sizeChanged || panel.frame.size != newSize {
            let origin: NSPoint
            if reanchorIfVisible, isShown, let button = anchorButton {
                origin = panelOrigin(relativeTo: button)
            } else if panel.frame.size != .zero {
                // Keep the top edge stable when the panel shrinks or grows.
                let topY = panel.frame.maxY
                origin = NSPoint(x: panel.frame.minX, y: topY - newSize.height)
            } else {
                origin = panel.frame.origin
            }

            panel.setFrame(NSRect(origin: origin, size: newSize), display: true)
            panel.setContentSize(newSize)
            panel.invalidateShadow()
        }
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

    private func panelOrigin(relativeTo button: NSStatusBarButton) -> NSPoint {
        guard let buttonFrame = screenRect(for: button) else {
            return NSPoint(x: 0, y: 0)
        }

        let visibleFrame = button.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let margin: CGFloat = 10
        let verticalOffset: CGFloat = 8

        let proposedX = buttonFrame.midX - (panelSize.width / 2)
        let maxX = max(visibleFrame.minX + margin, visibleFrame.maxX - panelSize.width - margin)
        let originX = min(max(proposedX, visibleFrame.minX + margin), maxX)

        let proposedY = buttonFrame.minY - panelSize.height - verticalOffset
        let originY = max(visibleFrame.minY + margin, proposedY)

        return NSPoint(x: originX, y: originY)
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
