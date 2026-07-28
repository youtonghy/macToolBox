# Scroll-Wheel Slider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every slider in ToolBox adjust by its configured step while the pointer is over it and the user scrolls vertically.

**Architecture:** Add one shared `NSViewRepresentable` backed by an `NSSlider` subclass. Keep wheel normalization in a pure `ScrollWheelValueAdjuster` so discrete wheel, precise trackpad, snapping, reversal, disabled state, and bounds are deterministic and directly testable.

**Tech Stack:** Swift 5, SwiftUI, AppKit, XCTest, XcodeGen, macOS 14+

---

### Task 1: Test and implement wheel value adjustment

**Files:**
- Create: `Tests/ToolBoxTests/ScrollWheelSliderTests.swift`
- Create: `Sources/ToolBox/ScrollWheelSlider.swift`

- [ ] **Step 1: Write the failing adjustment tests**

Create `ScrollWheelSliderTests` with tests that instantiate `ScrollWheelValueAdjuster(preciseThreshold: 10)` and assert these exact behaviors:

```swift
import XCTest
@testable import ToolBox

final class ScrollWheelSliderTests: XCTestCase {
    func testDiscreteWheelMovesOneStepInEitherDirection() {
        var adjuster = ScrollWheelValueAdjuster(preciseThreshold: 10)
        XCTAssertEqual(adjuster.value(afterScrolling: 1, isPrecise: false, currentValue: 40, range: 0...100, step: 1, isEnabled: true), 41)
        XCTAssertEqual(adjuster.value(afterScrolling: -1, isPrecise: false, currentValue: 41, range: 0...100, step: 1, isEnabled: true), 40)
    }

    func testDiscreteWheelUsesDeltaMagnitudeAndSnapsFromRangeLowerBound() {
        var adjuster = ScrollWheelValueAdjuster(preciseThreshold: 10)
        XCTAssertEqual(adjuster.value(afterScrolling: 2, isPrecise: false, currentValue: 10.25, range: 10...20, step: 0.25, isEnabled: true), 10.75, accuracy: 0.000_001)
    }

    func testWheelValueIsClampedToRange() {
        var adjuster = ScrollWheelValueAdjuster(preciseThreshold: 10)
        XCTAssertEqual(adjuster.value(afterScrolling: 2, isPrecise: false, currentValue: 99, range: 0...100, step: 1, isEnabled: true), 100)
        XCTAssertEqual(adjuster.value(afterScrolling: -2, isPrecise: false, currentValue: 1, range: 0...100, step: 1, isEnabled: true), 0)
    }

    func testPreciseWheelAccumulatesAndCanCrossMultipleThresholds() {
        var adjuster = ScrollWheelValueAdjuster(preciseThreshold: 10)
        XCTAssertEqual(adjuster.value(afterScrolling: 4, isPrecise: true, currentValue: 50, range: 0...100, step: 1, isEnabled: true), 50)
        XCTAssertEqual(adjuster.value(afterScrolling: 7, isPrecise: true, currentValue: 50, range: 0...100, step: 1, isEnabled: true), 51)
        XCTAssertEqual(adjuster.value(afterScrolling: 21, isPrecise: true, currentValue: 51, range: 0...100, step: 1, isEnabled: true), 53)
    }

    func testPreciseWheelDropsRemainderWhenDirectionReverses() {
        var adjuster = ScrollWheelValueAdjuster(preciseThreshold: 10)
        XCTAssertEqual(adjuster.value(afterScrolling: 8, isPrecise: true, currentValue: 50, range: 0...100, step: 1, isEnabled: true), 50)
        XCTAssertEqual(adjuster.value(afterScrolling: -3, isPrecise: true, currentValue: 50, range: 0...100, step: 1, isEnabled: true), 50)
        XCTAssertEqual(adjuster.value(afterScrolling: -7, isPrecise: true, currentValue: 50, range: 0...100, step: 1, isEnabled: true), 49)
    }

    func testDisabledWheelDoesNotChangeValueOrAccumulate() {
        var adjuster = ScrollWheelValueAdjuster(preciseThreshold: 10)
        XCTAssertEqual(adjuster.value(afterScrolling: 9, isPrecise: true, currentValue: 50, range: 0...100, step: 1, isEnabled: false), 50)
        XCTAssertEqual(adjuster.value(afterScrolling: 1, isPrecise: true, currentValue: 50, range: 0...100, step: 1, isEnabled: true), 50)
    }
}
```

- [ ] **Step 2: Generate the project and verify the tests fail**

Run:

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' -only-testing:ToolBoxTests/ScrollWheelSliderTests CODE_SIGNING_ALLOWED=NO
```

Expected: build failure because `ScrollWheelValueAdjuster` is not defined.

- [ ] **Step 3: Add the minimal pure adjustment implementation**

Create the pure internal value type at the top of `Sources/ToolBox/ScrollWheelSlider.swift`:

```swift
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
            if !isEnabled { resetPreciseScrolling() }
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
            let wholeSteps = Int(delta.rounded(.towardZero))
            stepCount = wholeSteps == 0 ? (delta > 0 ? 1 : -1) : wholeSteps
        }

        guard stepCount != 0 else { return currentValue }
        let proposed = currentValue + Double(stepCount) * step
        return Self.snappedValue(proposed, range: range, step: step)
    }
}
```

- [ ] **Step 4: Run the focused tests and verify they pass**

Run the focused `xcodebuild test` command from Step 2.

Expected: 6 tests pass with 0 failures.

### Task 2: Add the native slider bridge and replace all SwiftUI sliders

**Files:**
- Modify: `Sources/ToolBox/ScrollWheelSlider.swift`
- Modify: `Sources/ToolBox/DisplayControl/DisplayControlPanel.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioRoutingPanel.swift`
- Modify: `Sources/ToolBox/SettingsView.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioRoutingSettingsView.swift`
- Modify: `Sources/ToolBox/DisplayControl/Schedule/BrightnessScheduleSettingsView.swift`

- [ ] **Step 1: Add the AppKit slider subclass**

Append `ScrollWheelNSSlider`, with an owned adjuster and this event policy:

```swift
final class ScrollWheelNSSlider: NSSlider {
    var wheelStep = 1.0
    private var wheelAdjuster = ScrollWheelValueAdjuster()

    override func scrollWheel(with event: NSEvent) {
        if event.phase.contains(.began) {
            wheelAdjuster.resetPreciseScrolling()
        }

        guard isEnabled, event.scrollingDeltaY != 0 else {
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
```

Enabled vertical events are intentionally not forwarded to `super`, including at a bound, so a parent `ScrollView` cannot move while the pointer is over the slider. Disabled and horizontal events continue through AppKit's responder chain.

- [ ] **Step 2: Add the SwiftUI representable**

Append `ScrollWheelSlider`, with initializer signature matching SwiftUI call sites:

```swift
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
```

- [ ] **Step 3: Replace all six `Slider` expressions**

In each listed view file, replace `Slider(` with `ScrollWheelSlider(` without changing bindings, ranges, steps, modifiers, help text, or disabled conditions. Verify with:

```bash
rg -n '\bSlider\s*\(' Sources/ToolBox
rg -n 'ScrollWheelSlider\s*\(' Sources/ToolBox
```

Expected: the first command reports no call sites; the second reports 6 call sites.

- [ ] **Step 4: Run focused tests and build**

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' -only-testing:ToolBoxTests/ScrollWheelSliderTests CODE_SIGNING_ALLOWED=NO
xcodebuild build -project ToolBox.xcodeproj -scheme ToolBox -configuration Debug CODE_SIGNING_ALLOWED=NO
```

Expected: both commands exit 0; the focused suite reports 6 passing tests.

### Task 3: Full verification and quality review

**Files:**
- Review all files changed by Tasks 1 and 2

- [ ] **Step 1: Run the complete unit test target**

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: all `ToolBoxTests` pass with 0 failures.

- [ ] **Step 2: Run repository consistency checks**

```bash
git diff --check
git status --short
```

Expected: `git diff --check` exits 0. Review `git status` to distinguish this feature from the user's pre-existing changes.

- [ ] **Step 3: Review behavioral and code-quality risks**

Confirm from the final diff that there is one wheel implementation, every original range and step is unchanged, disabled controls forward rather than consume scroll, enabled vertical scroll is consumed at bounds, bindings receive AppKit target/action updates, and no event monitors or retained closures were introduced.

- [ ] **Step 4: Record manual verification still required**

Report that real-device checks remain for mouse direction, trackpad sensitivity, hover hit testing, native appearance, dragging, keyboard adjustment, VoiceOver, and parent-scroll suppression. Do not claim these behaviors were manually verified unless the built app was exercised with those inputs.
