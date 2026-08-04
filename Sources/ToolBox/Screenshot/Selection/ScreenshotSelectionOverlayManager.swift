import AppKit

enum ScreenshotSelectionOverlayError: Error, Equatable {
    case emptyFrames
    case duplicateDisplay(CGDirectDisplayID)
}

final class ScreenshotSelectionPanel: NSPanel {
    var keyEnabled = false
    override var canBecomeKey: Bool { keyEnabled }
    override var canBecomeMain: Bool { false }
}

@MainActor
protocol ScreenshotSelectionOverlayManaging: AnyObject {
    func show(
        frames: [DisplayCaptureFrame],
        state: SelectionSessionState,
        onAction: @escaping (SelectionAction) -> Void,
        onHover: @escaping (CGPoint) -> Void,
        onCancel: @escaping () -> Void
    ) throws
    func beginInteraction(on displayID: CGDirectDisplayID)
    func update(state: SelectionSessionState)
    func close(cancelled: Bool)
}

@MainActor
final class ScreenshotSelectionOverlayManager: ScreenshotSelectionOverlayManaging {
    private let activateApplication: Bool
    private let restorePreviousApplication: () -> Void
    private var panels: [CGDirectDisplayID: ScreenshotSelectionPanel] = [:]
    private var views: [CGDirectDisplayID: ScreenshotSelectionView] = [:]
    private var closed = true
    private var onAction: (SelectionAction) -> Void = { _ in }
    private var onHover: (CGPoint) -> Void = { _ in }
    private var onCancel: () -> Void = {}

    init(
        activateApplication: Bool = true,
        restorePreviousApplication: (() -> Void)? = nil
    ) {
        self.activateApplication = activateApplication
        let previous = NSWorkspace.shared.frontmostApplication
        self.restorePreviousApplication = restorePreviousApplication ?? {
            previous?.activate()
        }
    }

    var panelCount: Int { panels.count }

    func panel(for displayID: CGDirectDisplayID) -> ScreenshotSelectionPanel? {
        panels[displayID]
    }

    func show(
        frames: [DisplayCaptureFrame],
        state: SelectionSessionState,
        onAction: @escaping (SelectionAction) -> Void = { _ in },
        onHover: @escaping (CGPoint) -> Void = { _ in },
        onCancel: @escaping () -> Void = {}
    ) throws {
        guard !frames.isEmpty else { throw ScreenshotSelectionOverlayError.emptyFrames }
        close(cancelled: false)
        self.onAction = onAction
        self.onHover = onHover
        self.onCancel = onCancel
        closed = false

        for frame in frames {
            let displayID = frame.geometry.displayID
            guard panels[displayID] == nil else {
                close(cancelled: false)
                throw ScreenshotSelectionOverlayError.duplicateDisplay(displayID)
            }
            let displayFrame = frame.geometry.globalFramePoints
            let panel = ScreenshotSelectionPanel(
                contentRect: displayFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.animationBehavior = .none
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = ScreenshotSelectionView(
                frame: CGRect(origin: .zero, size: displayFrame.size),
                displayFrame: displayFrame,
                image: frame.image,
                state: state,
                onAction: { [weak self] action in self?.onAction(action) },
                onHover: { [weak self] point in self?.onHover(point) },
                onInteraction: { [weak self] in self?.beginInteraction(on: displayID) },
                onCancel: { [weak self] in self?.cancel() }
            )
            panel.contentView = view
            panels[displayID] = panel
            views[displayID] = view
        }

        if activateApplication {
            NSApp.activate()
            panels.values.forEach { $0.orderFront(nil) }
        }
    }

    func beginInteraction(on displayID: CGDirectDisplayID) {
        for (id, panel) in panels {
            panel.keyEnabled = id == displayID
        }
        guard activateApplication, let panel = panels[displayID] else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.contentView?.window?.makeFirstResponder(panel.contentView)
    }

    func update(state: SelectionSessionState) {
        views.values.forEach { $0.update(state: state) }
    }

    func cancel() {
        onCancel()
        close(cancelled: true)
    }

    func close(cancelled: Bool) {
        guard !closed else { return }
        closed = true
        views.values.forEach { $0.prepareForRemoval() }
        panels.values.forEach { $0.close() }
        panels.removeAll()
        views.removeAll()
        if cancelled { restorePreviousApplication() }
    }
}
