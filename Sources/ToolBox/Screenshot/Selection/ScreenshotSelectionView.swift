import AppKit

// MARK: - Magnifier Popup

final class MagnifierView: NSView {
    private let sourceImage: CGImage
    var magnifiedPoint: CGPoint
    private let displayFrame: CGRect
    private let magnification: CGFloat = 4
    private let radius: CGFloat = 50

    init(sourceImage: CGImage, magnifiedPoint: CGPoint, displayFrame: CGRect) {
        self.sourceImage = sourceImage
        self.magnifiedPoint = magnifiedPoint
        self.displayFrame = displayFrame
        let size = radius * 2
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let pixelRadius = radius / magnification
        // Convert global screen point to image pixel coordinates
        let xScale = CGFloat(sourceImage.width) / displayFrame.width
        let yScale = CGFloat(sourceImage.height) / displayFrame.height
        let pixelCenter = CGPoint(
            x: (magnifiedPoint.x - displayFrame.minX) * xScale,
            y: (displayFrame.maxY - magnifiedPoint.y) * yScale
        )
        let sourceRect = CGRect(
            x: pixelCenter.x - pixelRadius,
            y: pixelCenter.y - pixelRadius,
            width: pixelRadius * 2,
            height: pixelRadius * 2
        )

        NSColor.windowBackgroundColor.setFill()
        context.fill(bounds)

        // Draw magnified image
        guard let crop = sourceImage.cropping(to: sourceRect) else { return }
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(crop, in: bounds)
        context.restoreGState()

        // Draw crosshair at center
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let crosshairLen: CGFloat = 8
        NSColor.white.setStroke()
        NSBezierPath.defaultLineWidth = 1
        let hPath = NSBezierPath()
        hPath.move(to: CGPoint(x: center.x - crosshairLen, y: center.y))
        hPath.line(to: CGPoint(x: center.x + crosshairLen, y: center.y))
        hPath.stroke()
        let vPath = NSBezierPath()
        vPath.move(to: CGPoint(x: center.x, y: center.y - crosshairLen))
        vPath.line(to: CGPoint(x: center.x, y: center.y + crosshairLen))
        vPath.stroke()

        // Draw pixel grid
        NSColor.separatorColor.withAlphaComponent(0.3).setStroke()
        NSBezierPath.defaultLineWidth = 0.5
        let step = magnification
        var x: CGFloat = 0
        while x <= bounds.width {
            let line = NSBezierPath()
            line.move(to: CGPoint(x: x, y: 0))
            line.line(to: CGPoint(x: x, y: bounds.height))
            line.stroke()
            x += step
        }
        var y: CGFloat = 0
        while y <= bounds.height {
            let line = NSBezierPath()
            line.move(to: CGPoint(x: 0, y: y))
            line.line(to: CGPoint(x: bounds.width, y: y))
            line.stroke()
            y += step
        }
    }
}

// MARK: - Selection Handle

private enum HandlePosition: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    case top, left, bottom, right

    var cursor: NSCursor {
        switch self {
        case .topLeft, .bottomRight: return .crosshair
        case .topRight, .bottomLeft: return .crosshair
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        }
    }
}

private struct SelectionHandle {
    let position: HandlePosition
    let rect: CGRect
}

// MARK: - ScreenshotSelectionView

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
    private var pendingClickCandidate: SelectionCandidate?
    private var mouseScreenPoint: CGPoint?
    private var magnifierWindow: NSWindow?
    private var draggingHandle: HandlePosition?
    private var shiftPressed = false
    private var hierarchyScrollAccumulator: CGFloat = 0

    private let handleSize: CGFloat = 8
    private let infoBarHeight: CGFloat = 36

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
        wantsLayer = true
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
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

    func prepareForRemoval() {
        hideMagnifier()
        dragStart = nil
        dragCurrent = nil
        pendingClickCandidate = nil
        draggingHandle = nil
        mouseScreenPoint = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            prepareForRemoval()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        context.draw(image, in: bounds)

        let hasSelection = state.captureBounds != nil

        // Keep the frozen image intact and paint only outside the chosen regions.
        if hasSelection, let captureBounds = state.captureBounds {
            let highlightedRects = state.selectedRegions.isEmpty
                ? [captureBounds]
                : state.selectedRegions.map(\.globalRect)
            context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
            context.fill(bounds)
            for globalRect in highlightedRects {
                let rect = localRect(for: globalRect).intersection(bounds)
                guard !rect.isNull else { continue }
                context.saveGState()
                context.clip(to: rect)
                context.draw(image, in: bounds)
                context.restoreGState()
            }
        }

        // Draw hovered candidate
        if let hovered = state.hoveredCandidate {
            drawSelectionBorder(globalRect: hovered.globalRect, color: .systemBlue, width: 4, in: context)
        }

        // Draw selected regions
        for region in state.selectedRegions {
            drawSelectionBorder(globalRect: region.globalRect, color: .systemBlue, width: 4, in: context)
            drawHandles(globalRect: region.globalRect, in: context)
        }

        // Draw drag rect
        if let start = dragStart, let current = dragCurrent {
            let rect = normalizedRect(from: start, to: current)
            drawSelectionBorder(globalRect: rect, color: .white, width: 2, in: context)
            drawInfoBar(globalRect: rect, in: context)
        }

        // Draw info bar for existing selection
        if let bounds = state.captureBounds, hasSelection {
            drawInfoBar(globalRect: bounds, in: context)
        }

        // Draw capture controls
        drawCaptureControls(in: context)
    }

    private func drawSelectionBorder(globalRect: CGRect, color: NSColor, width: CGFloat, in context: CGContext) {
        let rect = localRect(for: globalRect).intersection(bounds)
        guard !rect.isNull else { return }
        let outlineWidth = width + 4
        NSColor.black.withAlphaComponent(0.75).setStroke()
        let outline = NSBezierPath(rect: rect.insetBy(dx: outlineWidth / 2, dy: outlineWidth / 2))
        outline.lineWidth = outlineWidth
        outline.stroke()
        color.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: width / 2, dy: width / 2))
        path.lineWidth = width
        path.stroke()
    }

    private func drawHandles(globalRect: CGRect, in context: CGContext) {
        let handles = handlesFor(globalRect: globalRect)
        for handle in handles {
            let path = NSBezierPath(roundedRect: handle.rect, xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            path.fill()
            NSColor.systemBlue.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawInfoBar(globalRect: CGRect, in context: CGContext) {
        let rect = localRect(for: globalRect)
        let label = "\(Int(rect.width)) × \(Int(rect.height))"
        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (label as NSString).size(withAttributes: attr)
        let barWidth = size.width + 24
        let barHeight: CGFloat = 28
        let barX = rect.midX - barWidth / 2
        let barY = rect.minY - barHeight - 6

        let barRect = CGRect(x: barX, y: barY, width: barWidth, height: barHeight)
        let barPath = NSBezierPath(roundedRect: barRect, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        barPath.fill()

        let textPoint = CGPoint(
            x: barRect.midX - size.width / 2,
            y: barRect.midY - size.height / 2
        )
        (label as NSString).draw(at: textPoint, withAttributes: attr)
    }

    private func drawCaptureControls(in context: CGContext) {
        let buttons: [(CGRect, String, String, SelectionCaptureMode)] = [
            (staticCaptureButtonRect, "camera", "截图", .staticCapture),
            (scrollCaptureButtonRect, "rectangle.and.arrow.up.right.and.arrow.down.left", "滚动截图", .scrollCapture),
        ]
        for (rect, symbol, help, mode) in buttons {
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            let selected = state.captureMode == mode
            (selected ? NSColor.controlAccentColor : NSColor.windowBackgroundColor)
                .withAlphaComponent(selected ? 0.95 : 0.92)
                .setFill()
            path.fill()
            (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = 1
            path.stroke()
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help) {
                image.isTemplate = true
                image.draw(in: rect.insetBy(dx: 10, dy: 7))
            }
        }
    }

    // MARK: - Handle Detection

    private func handlesFor(globalRect: CGRect) -> [SelectionHandle] {
        let rect = localRect(for: globalRect)
        let half = handleSize / 2
        let positions: [(HandlePosition, CGRect)] = [
            (.topLeft, CGRect(x: rect.minX - half, y: rect.minY - half, width: handleSize, height: handleSize)),
            (.topRight, CGRect(x: rect.maxX - half, y: rect.minY - half, width: handleSize, height: handleSize)),
            (.bottomLeft, CGRect(x: rect.minX - half, y: rect.maxY - half, width: handleSize, height: handleSize)),
            (.bottomRight, CGRect(x: rect.maxX - half, y: rect.maxY - half, width: handleSize, height: handleSize)),
            (.top, CGRect(x: rect.midX - half, y: rect.minY - half, width: handleSize, height: handleSize)),
            (.bottom, CGRect(x: rect.midX - half, y: rect.maxY - half, width: handleSize, height: handleSize)),
            (.left, CGRect(x: rect.minX - half, y: rect.midY - half, width: handleSize, height: handleSize)),
            (.right, CGRect(x: rect.maxX - half, y: rect.midY - half, width: handleSize, height: handleSize)),
        ]
        return positions.map { SelectionHandle(position: $0.0, rect: $0.1) }
    }

    private func handleAt(localPoint: CGPoint) -> HandlePosition? {
        for region in state.selectedRegions {
            let handles = handlesFor(globalRect: region.globalRect)
            for handle in handles {
                if handle.rect.insetBy(dx: -4, dy: -4).contains(localPoint) {
                    return handle.position
                }
            }
        }
        return nil
    }

    // MARK: - Magnifier

    private func showMagnifier(at screenPoint: CGPoint) {
        guard magnifierWindow == nil else {
            updateMagnifierPosition(at: screenPoint)
            return
        }
        let magnifier = MagnifierView(sourceImage: image, magnifiedPoint: screenPoint, displayFrame: displayFrame)
        let magnifierSize = magnifier.bounds.size
        let window = NSWindow(
            contentRect: NSRect(x: screenPoint.x + 20, y: screenPoint.y - magnifierSize.height,
                                width: magnifierSize.width, height: magnifierSize.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver + 1
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = magnifier
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.orderFront(nil)
        magnifierWindow = window
    }

    private func updateMagnifierPosition(at screenPoint: CGPoint) {
        guard let window = magnifierWindow else { return }
        let size = window.frame.size
        var x = screenPoint.x + 20
        var y = screenPoint.y - size.height
        // Keep within screen bounds
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            if x + size.width > screenFrame.maxX { x = screenPoint.x - size.width - 20 }
            if y < screenFrame.minY { y = screenPoint.y + 20 }
        }
        window.setFrameOrigin(NSPoint(x: x, y: y))
        (window.contentView as? MagnifierView)?.magnifiedPoint = screenPoint
        window.contentView?.needsDisplay = true
    }

    private func hideMagnifier() {
        magnifierWindow?.close()
        magnifierWindow = nil
    }

    // MARK: - Mouse Events

    override func mouseMoved(with event: NSEvent) {
        let point = globalPoint(for: event)
        mouseScreenPoint = point
        hierarchyScrollAccumulator = 0
        onHover(point)

        // Show magnifier
        if let localPoint = localPoint(for: event) {
            let handle = handleAt(localPoint: localPoint)
            if handle == nil {
                showMagnifier(at: point)
            } else {
                hideMagnifier()
            }
        }
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        mouseScreenPoint = globalPoint(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        hideMagnifier()
        mouseScreenPoint = nil
    }

    override func mouseDown(with event: NSEvent) {
        onInteraction()
        hideMagnifier()
        let local = convert(event.locationInWindow, from: nil)

        // Check buttons
        if staticCaptureButtonRect.contains(local) {
            onAction(.setCaptureMode(.staticCapture))
            return
        }
        if scrollCaptureButtonRect.contains(local) {
            onAction(.setCaptureMode(.scrollCapture))
            return
        }

        let point = globalPoint(for: event)
        let shiftDown = event.modifierFlags.contains(.shift)
        if shiftDown { shiftPressed = true }

        if state.captureMode == .staticCapture, shiftDown {
            if let candidate = state.hoveredCandidate, candidate.globalRect.contains(point) {
                onAction(.click(candidate, additive: true))
            }
            return
        }

        // Check if clicking on a handle
        if let handle = handleAt(localPoint: local) {
            draggingHandle = handle
            dragStart = point
            dragCurrent = point
            return
        }

        // Double-click to confirm
        if event.clickCount == 2, state.captureBounds != nil {
            onAction(.confirm)
            return
        }

        // Click on candidate
        if let candidate = state.hoveredCandidate, candidate.globalRect.contains(point) {
            pendingClickCandidate = candidate
            dragStart = point
            dragCurrent = point
            return
        }

        // Start drag
        dragStart = point
        dragCurrent = point
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let current = globalPoint(for: event)
        dragCurrent = current

        if let handle = draggingHandle, let bounds = state.captureBounds {
            // Adjust selection via handle drag
            var newRect = bounds
            let dx = current.x - start.x
            let dy = current.y - start.y
            switch handle {
            case .topLeft: newRect = CGRect(x: bounds.minX + dx, y: bounds.minY + dy, width: bounds.width - dx, height: bounds.height - dy)
            case .topRight: newRect = CGRect(x: bounds.minX, y: bounds.minY + dy, width: bounds.width + dx, height: bounds.height - dy)
            case .bottomLeft: newRect = CGRect(x: bounds.minX + dx, y: bounds.minY, width: bounds.width - dx, height: bounds.height + dy)
            case .bottomRight: newRect = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width + dx, height: bounds.height + dy)
            case .top: newRect = CGRect(x: bounds.minX, y: bounds.minY + dy, width: bounds.width, height: bounds.height - dy)
            case .bottom: newRect = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height + dy)
            case .left: newRect = CGRect(x: bounds.minX + dx, y: bounds.minY, width: bounds.width - dx, height: bounds.height)
            case .right: newRect = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width + dx, height: bounds.height)
            }
            let standardized = newRect.standardized
            if standardized.width >= 4, standardized.height >= 4 {
                onAction(.adjustRegion(standardized))
            }
        }

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        hideMagnifier()
        guard let start = dragStart, draggingHandle == nil else {
            dragStart = nil
            dragCurrent = nil
            draggingHandle = nil
            needsDisplay = true
            return
        }
        let rect = normalizedRect(from: start, to: globalPoint(for: event))
        let pendingCandidate = pendingClickCandidate
        dragStart = nil
        dragCurrent = nil
        draggingHandle = nil
        pendingClickCandidate = nil
        needsDisplay = true
        if rect.width >= 3 || rect.height >= 3 {
            onAction(.manualDrag(rect))
        } else if let pendingCandidate {
            onAction(.click(pendingCandidate, additive: false))
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard dragStart == nil, draggingHandle == nil else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        if event.hasPreciseScrollingDeltas {
            hierarchyScrollAccumulator += delta
            guard abs(hierarchyScrollAccumulator) >= 10 else { return }
            hierarchyScrollAccumulator = 0
        } else {
            hierarchyScrollAccumulator = 0
        }
        onAction(.cycleCandidate(delta < 0 ? 1 : -1))
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            hideMagnifier()
            onCancel()
        case 51, 117:
            onAction(.deleteLast)
        case 6 where event.modifierFlags.contains(.command):
            // Z key
            onAction(.undo)
        case 36, 76:
            // Enter/Return
            hideMagnifier()
            onAction(.confirm)
        case 123: // Left arrow
            handleArrowKey(dx: -1, dy: 0, event: event)
        case 124: // Right arrow
            handleArrowKey(dx: 1, dy: 0, event: event)
        case 125: // Down arrow
            handleArrowKey(dx: 0, dy: -1, event: event)
        case 126: // Up arrow
            handleArrowKey(dx: 0, dy: 1, event: event)
        default:
            super.keyDown(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let isShiftDown = event.modifierFlags.contains(.shift)
        if shiftPressed,
           !isShiftDown,
           state.captureMode == .staticCapture,
           state.captureBounds != nil {
            hideMagnifier()
            onAction(.confirm)
        }
        shiftPressed = isShiftDown
        needsDisplay = true
    }

    private func handleArrowKey(dx: CGFloat, dy: CGFloat, event: NSEvent) {
        guard let bounds = state.captureBounds else { return }
        let shift = event.modifierFlags.contains(.shift)
        let ctrl = event.modifierFlags.contains(.control)

        if shift {
            return
        } else if ctrl {
            // Expand: move the opposite edge outward
            var newRect = bounds
            if dx < 0 { newRect = CGRect(x: bounds.minX + dx, y: bounds.minY, width: bounds.width - dx, height: bounds.height) }
            if dx > 0 { newRect = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width - dx, height: bounds.height) }
            if dy < 0 { newRect = CGRect(x: bounds.minX, y: bounds.minY + dy, width: bounds.width, height: bounds.height - dy) }
            if dy > 0 { newRect = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height - dy) }
            let std = newRect.standardized
            if std.width >= 4, std.height >= 4 {
                onAction(.adjustRegion(std))
            }
        } else {
            // Move whole selection
            let newRect = bounds.offsetBy(dx: dx, dy: dy)
            onAction(.adjustRegion(newRect))
        }
    }

    // MARK: - Utilities

    private func globalPoint(for event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: displayFrame.minX + local.x, y: displayFrame.minY + local.y)
    }

    private func localPoint(for event: NSEvent) -> CGPoint? {
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local) else { return nil }
        return local
    }

    private func localRect(for globalRect: CGRect) -> CGRect {
        CGRect(
            x: globalRect.minX - displayFrame.minX,
            y: globalRect.minY - displayFrame.minY,
            width: globalRect.width,
            height: globalRect.height
        )
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
}
