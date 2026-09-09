import AppKit
import SwiftUI

struct ScrollWheelValueAdjuster {
    let preciseThreshold: Double
    private var preciseRemainder = 0.0

    init(preciseThreshold: Double = 10) {
        precondition(preciseThreshold > 0)
        self.preciseThreshold = preciseThreshold
    }

    mutating func resetPreciseScrolling() {
        preciseRemainder = 0
    }

    static func snappedValue(
        _ proposed: Double,
        range: ClosedRange<Double>,
        step: Double
    ) -> Double {
        let snappedSteps = ((proposed - range.lowerBound) / step).rounded()
        let snapped = range.lowerBound + snappedSteps * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    mutating func value(
        afterScrolling delta: Double,
        isPrecise: Bool,
        currentValue: Double,
        range: ClosedRange<Double>,
        step: Double,
        isEnabled: Bool
    ) -> Double {
        precondition(range.lowerBound <= range.upperBound)
        precondition(step > 0)

        guard isEnabled, delta != 0 else {
            if !isEnabled {
                resetPreciseScrolling()
            }
            return currentValue
        }

        let stepCount: Int
        if isPrecise {
            if preciseRemainder != 0, preciseRemainder.sign != delta.sign {
                preciseRemainder = 0
            }
            preciseRemainder += delta
            stepCount = Int(preciseRemainder / preciseThreshold)
            preciseRemainder -= Double(stepCount) * preciseThreshold
        } else {
            preciseRemainder = 0
            stepCount = delta > 0 ? 1 : -1
        }

        guard stepCount != 0 else { return currentValue }
        let proposed = currentValue + Double(stepCount) * step
        return Self.snappedValue(proposed, range: range, step: step)
    }
}

final class RangeExpandableSliderCell: NSSliderCell {
    static func isDraggingTowardMaximum(
        lastPoint: NSPoint,
        currentPoint: NSPoint,
        isFlipped: Bool
    ) -> Bool {
        isFlipped ? currentPoint.y < lastPoint.y : currentPoint.y > lastPoint.y
    }

    override func continueTracking(
        last lastPoint: NSPoint,
        current currentPoint: NSPoint,
        in controlView: NSView
    ) -> Bool {
        let shouldContinue = super.continueTracking(last: lastPoint, current: currentPoint, in: controlView)
        guard let slider = controlView as? ScrollWheelNSSlider,
              slider.isVertical,
              slider.doubleValue >= slider.maxValue,
              Self.isDraggingTowardMaximum(
                  lastPoint: lastPoint,
                  currentPoint: currentPoint,
                  isFlipped: controlView.isFlipped
              ) else {
            return shouldContinue
        }
        slider.requestRangeExpansion()
        return shouldContinue
    }
}

final class ScrollWheelNSSlider: NSSlider {
    var wheelStep = 1.0
    /// When true, a mouse click only claims keyboard focus: the click must not
    /// jump the value (the slider is invisible overlay decoration), but arrow-key
    /// control requires first-responder status, so the click cannot be dropped
    /// entirely.
    var focusOnlyOnClick = false {
        didSet {
            guard oldValue != focusOnlyOnClick else { return }
            if focusOnlyOnClick {
                installLocalEventMonitorIfNeeded()
            } else {
                removeLocalEventMonitor()
            }
        }
    }
    var onRequestRangeExpansion: (() -> Void)?
    private(set) var isRangeExpansionPending = false
    private var wheelAdjuster = ScrollWheelValueAdjuster()
    private var localEventMonitor: Any?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        removeLocalEventMonitor()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installLocalEventMonitorIfNeeded()
    }

    deinit {
        removeLocalEventMonitor()
    }

    /// A Lite-mode slider sits below the reset button, so AppKit's normal hit
    /// testing sends wheel events to the button instead. A local monitor lets
    /// the invisible slider consume vertical wheels across its whole tile while
    /// leaving ordinary mouse events available to the button.
    private func installLocalEventMonitorIfNeeded() {
        guard focusOnlyOnClick, localEventMonitor == nil, window != nil else { return }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseDown]
        ) { [weak self] event in
            guard let self,
                  self.focusOnlyOnClick,
                  self.isEnabled,
                  let window = self.window,
                  event.window === window
            else {
                return event
            }

            let location = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(location) else {
                return event
            }

            if event.type == .leftMouseDown {
                // Keep the reset button's click intact while making the tile
                // keyboard-focusable, including when the click lands on the icon.
                window.makeFirstResponder(self)
                return event
            }

            guard event.type == .scrollWheel,
                  self.shouldCaptureLocalScrollWheel(at: location, deltaY: event.scrollingDeltaY) else {
                return event
            }
            self.scrollWheel(with: event)
            return nil
        }
    }

    func shouldCaptureLocalScrollWheel(at location: NSPoint, deltaY: CGFloat) -> Bool {
        focusOnlyOnClick && isEnabled && deltaY != 0 && bounds.contains(location)
    }

    private func removeLocalEventMonitor() {
        guard let localEventMonitor else { return }
        NSEvent.removeMonitor(localEventMonitor)
        self.localEventMonitor = nil
    }

    func requestRangeExpansion() {
        guard !isRangeExpansionPending, let onRequestRangeExpansion else { return }
        isRangeExpansionPending = true
        onRequestRangeExpansion()
    }

    func finishRangeExpansion() {
        isRangeExpansionPending = false
    }

    override func mouseDown(with event: NSEvent) {
        guard !focusOnlyOnClick else {
            window?.makeFirstResponder(self)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !focusOnlyOnClick else { return }
        super.mouseDragged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else {
            super.keyDown(with: event)
            return
        }
        // Up/Right increase, Down/Left decrease — the AppKit convention for both
        // slider orientations. (This previously mapped Left to increase, which is
        // inverted for the horizontal lite-mode slider.)
        let delta: Double
        switch event.keyCode {
        case 126, 124: delta = 1
        case 125, 123: delta = -1
        default:
            super.keyDown(with: event)
            return
        }
        if delta > 0, doubleValue >= maxValue {
            requestRangeExpansion()
            return
        }
        let updated = ScrollWheelValueAdjuster.snappedValue(
            doubleValue + delta * wheelStep,
            range: minValue...maxValue,
            step: wheelStep
        )
        guard updated != doubleValue else { return }
        doubleValue = updated
        sendAction(action, to: target)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.phase.contains(.began) {
            wheelAdjuster.resetPreciseScrolling()
        }

        guard isEnabled else {
            wheelAdjuster.resetPreciseScrolling()
            super.scrollWheel(with: event)
            return
        }

        guard event.scrollingDeltaY != 0 else {
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                wheelAdjuster.resetPreciseScrolling()
            }
            super.scrollWheel(with: event)
            return
        }

        let updated = wheelAdjuster.value(
            afterScrolling: event.scrollingDeltaY,
            isPrecise: event.hasPreciseScrollingDeltas,
            currentValue: doubleValue,
            range: minValue...maxValue,
            step: wheelStep,
            isEnabled: true
        )
        if event.scrollingDeltaY > 0, doubleValue >= maxValue {
            requestRangeExpansion()
            return
        }
        if updated != doubleValue {
            doubleValue = updated
            sendAction(action, to: target)
        }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            wheelAdjuster.resetPreciseScrolling()
        }
    }
}

struct ScrollWheelSlider: NSViewRepresentable {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double
    private let isVertical: Bool
    private let onRequestRangeExpansion: (() -> Void)?
    private let focusOnlyOnClick: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double = 1,
        isVertical: Bool = false,
        onRequestRangeExpansion: (() -> Void)? = nil,
        focusOnlyOnClick: Bool = false
    ) {
        precondition(range.lowerBound <= range.upperBound)
        precondition(step > 0)
        _value = value
        self.range = range
        self.step = step
        self.isVertical = isVertical
        self.onRequestRangeExpansion = onRequestRangeExpansion
        self.focusOnlyOnClick = focusOnlyOnClick
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, range: range, step: step, onRequestRangeExpansion: onRequestRangeExpansion)
    }

    func makeNSView(context: Context) -> ScrollWheelNSSlider {
        let slider = ScrollWheelNSSlider(frame: .zero)
        slider.cell = RangeExpandableSliderCell()
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.valueChanged(_:))
        slider.isContinuous = true
        slider.isVertical = isVertical
        slider.focusOnlyOnClick = focusOnlyOnClick
        slider.onRequestRangeExpansion = onRequestRangeExpansion
        return slider
    }

    func updateNSView(_ slider: ScrollWheelNSSlider, context: Context) {
        let previousMaximum = slider.maxValue
        context.coordinator.value = $value
        context.coordinator.range = range
        context.coordinator.step = step
        context.coordinator.onRequestRangeExpansion = onRequestRangeExpansion
        slider.minValue = range.lowerBound
        slider.onRequestRangeExpansion = onRequestRangeExpansion
        slider.focusOnlyOnClick = focusOnlyOnClick
        if slider.isVertical, previousMaximum != range.upperBound {
            slider.finishRangeExpansion()
            NSAnimationContext.runAnimationGroup { animationContext in
                animationContext.duration = 0.22
                slider.animator().maxValue = range.upperBound
            }
        } else {
            slider.maxValue = range.upperBound
        }
        slider.wheelStep = step
        slider.altIncrementValue = step
        slider.doubleValue = value
        slider.isEnabled = isEnabled
        slider.controlSize = appKitControlSize
        slider.isVertical = isVertical
    }

    private var appKitControlSize: NSControl.ControlSize {
        switch controlSize {
        case .mini: .mini
        case .small: .small
        case .regular: .regular
        case .large: .large
        default: .regular
        }
    }

    final class Coordinator: NSObject {
        var value: Binding<Double>
        var range: ClosedRange<Double>
        var step: Double
        var onRequestRangeExpansion: (() -> Void)?

        init(value: Binding<Double>, range: ClosedRange<Double>, step: Double, onRequestRangeExpansion: (() -> Void)?) {
            self.value = value
            self.range = range
            self.step = step
            self.onRequestRangeExpansion = onRequestRangeExpansion
        }

        @objc func valueChanged(_ sender: NSSlider) {
            let snapped = ScrollWheelValueAdjuster.snappedValue(
                sender.doubleValue,
                range: range,
                step: step
            )
            sender.doubleValue = snapped
            value.wrappedValue = snapped
        }
    }
}
