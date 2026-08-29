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
    override func continueTracking(
        last lastPoint: NSPoint,
        current currentPoint: NSPoint,
        in controlView: NSView
    ) -> Bool {
        let shouldContinue = super.continueTracking(last: lastPoint, current: currentPoint, in: controlView)
        guard let slider = controlView as? ScrollWheelNSSlider,
              slider.isVertical,
              slider.doubleValue >= slider.maxValue,
              currentPoint.y > controlView.bounds.maxY else {
            return shouldContinue
        }
        slider.onRequestRangeExpansion?()
        return shouldContinue
    }
}

final class ScrollWheelNSSlider: NSSlider {
    var wheelStep = 1.0
    var onRequestRangeExpansion: (() -> Void)?
    private var wheelAdjuster = ScrollWheelValueAdjuster()

    override func keyDown(with event: NSEvent) {
        let delta: Double
        switch event.keyCode {
        case 126, 123: delta = 1
        case 125, 124: delta = -1
        default:
            super.keyDown(with: event)
            return
        }
        if delta > 0, doubleValue >= maxValue {
            onRequestRangeExpansion?()
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
            onRequestRangeExpansion?()
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

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double = 1,
        isVertical: Bool = false,
        onRequestRangeExpansion: (() -> Void)? = nil
    ) {
        precondition(range.lowerBound <= range.upperBound)
        precondition(step > 0)
        _value = value
        self.range = range
        self.step = step
        self.isVertical = isVertical
        self.onRequestRangeExpansion = onRequestRangeExpansion
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
        if slider.isVertical, previousMaximum != range.upperBound {
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
