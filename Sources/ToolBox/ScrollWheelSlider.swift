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

final class ScrollWheelNSSlider: NSSlider {
    var wheelStep = 1.0
    private var wheelAdjuster = ScrollWheelValueAdjuster()

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

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 1) {
        precondition(range.lowerBound <= range.upperBound)
        precondition(step > 0)
        _value = value
        self.range = range
        self.step = step
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, range: range, step: step)
    }

    func makeNSView(context: Context) -> ScrollWheelNSSlider {
        let slider = ScrollWheelNSSlider(
            value: value,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: context.coordinator,
            action: #selector(Coordinator.valueChanged(_:))
        )
        slider.isContinuous = true
        return slider
    }

    func updateNSView(_ slider: ScrollWheelNSSlider, context: Context) {
        context.coordinator.value = $value
        context.coordinator.range = range
        context.coordinator.step = step
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.wheelStep = step
        slider.altIncrementValue = step
        slider.doubleValue = value
        slider.isEnabled = isEnabled
        slider.controlSize = appKitControlSize
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

        init(value: Binding<Double>, range: ClosedRange<Double>, step: Double) {
            self.value = value
            self.range = range
            self.step = step
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
