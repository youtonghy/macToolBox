import AppKit

final class ScreenshotSelectionView: NSView {
    let displayFrame: CGRect
    private let image: CGImage
    private var state: SelectionSessionState
    private let onAction: (SelectionAction) -> Void
    private let onHover: (CGPoint) -> Void
    private let onInteraction: () -> Void
    private let onCancel: () -> Void
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    init(
        frame: CGRect,
        displayFrame: CGRect,
        image: CGImage,
        state: SelectionSessionState,
        onAction: @escaping (SelectionAction) -> Void,
        onHover: @escaping (CGPoint) -> Void,
        onInteraction: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.displayFrame = displayFrame
        self.image = image
        self.state = state
        self.onAction = onAction
        self.onHover = onHover
        self.onInteraction = onInteraction
        self.onCancel = onCancel
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    func update(state: SelectionSessionState) {
        self.state = state
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        context.setFillColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        context.fill(bounds)

        for region in state.selectedRegions {
            stroke(globalRect: region.globalRect, color: .systemGreen, width: 2)
        }
        if let hovered = state.hoveredCandidate {
            stroke(globalRect: hovered.globalRect, color: .systemYellow, width: 2)
        }
        if let bounds = state.captureBounds {
            stroke(globalRect: bounds, color: .systemOrange, width: 3)
        }
        if let start = dragStart, let current = dragCurrent {
            stroke(globalRect: normalizedRect(from: start, to: current), color: .white, width: 1)
        }
        drawCaptureControls()
    }

    override func mouseMoved(with event: NSEvent) {
        onHover(globalPoint(for: event))
    }

    override func mouseDown(with event: NSEvent) {
        onInteraction()
        let local = convert(event.locationInWindow, from: nil)
        if staticCaptureButtonRect.contains(local) {
            onAction(.confirm)
            return
        }
        if scrollCaptureButtonRect.contains(local) {
            onAction(.confirmScroll)
            return
        }
        let point = globalPoint(for: event)
        if event.clickCount == 2, state.captureBounds != nil {
            onAction(.confirm)
        } else if let candidate = state.hoveredCandidate, candidate.globalRect.contains(point) {
            onAction(.click(candidate, additive: event.modifierFlags.contains(.shift)))
        } else {
            dragStart = point
            dragCurrent = point
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragCurrent = globalPoint(for: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        let rect = normalizedRect(from: start, to: globalPoint(for: event))
        dragStart = nil
        dragCurrent = nil
        needsDisplay = true
        if rect.width >= 2, rect.height >= 2 {
            onAction(.manualDrag(rect))
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel()
        case 51, 117: onAction(.deleteLast)
        case 6 where event.modifierFlags.contains(.command): onAction(.undo)
        case 36, 76:
            onAction(event.modifierFlags.contains(.option) ? .confirmScroll : .confirm)
        default: super.keyDown(with: event)
        }
    }

    private func globalPoint(for event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: displayFrame.minX + local.x, y: displayFrame.minY + local.y)
    }

    private func localRect(for globalRect: CGRect) -> CGRect {
        CGRect(
            x: globalRect.minX - displayFrame.minX,
            y: globalRect.minY - displayFrame.minY,
            width: globalRect.width,
            height: globalRect.height
        )
    }

    private func stroke(globalRect: CGRect, color: NSColor, width: CGFloat) {
        let rect = localRect(for: globalRect).intersection(bounds)
        guard !rect.isNull else { return }
        color.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: width / 2, dy: width / 2))
        path.lineWidth = width
        path.stroke()
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private var staticCaptureButtonRect: CGRect {
        CGRect(x: bounds.midX - 43, y: 18, width: 40, height: 34)
    }

    private var scrollCaptureButtonRect: CGRect {
        CGRect(x: bounds.midX + 3, y: 18, width: 40, height: 34)
    }

    private func drawCaptureControls() {
        for (rect, symbol, help) in [
            (staticCaptureButtonRect, "camera", "截图"),
            (scrollCaptureButtonRect, "rectangle.and.arrow.up.right.and.arrow.down.left", "滚动截图"),
        ] {
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help) {
                image.draw(in: rect.insetBy(dx: 10, dy: 7))
            }
        }
    }
}
