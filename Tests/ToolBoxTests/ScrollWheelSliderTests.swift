import AppKit
import XCTest
@testable import ToolBoxCore

final class ScrollWheelSliderTests: XCTestCase {
    func testAudioVolumeScaleExpandsInTwoSteps() {
        XCTAssertEqual(AudioVolumeScale.initialMaximum(for: 100), 100)
        XCTAssertEqual(AudioVolumeScale.initialMaximum(for: 150), 200)
        XCTAssertEqual(AudioVolumeScale.initialMaximum(for: 300), 300)
        XCTAssertEqual(AudioVolumeScale.nextMaximum(after: 100), 200)
        XCTAssertEqual(AudioVolumeScale.nextMaximum(after: 200), 300)
        XCTAssertNil(AudioVolumeScale.nextMaximum(after: 300))
    }

    func testDiscreteWheelMovesOneStepInEitherDirection() {
        var adjuster = ScrollWheelValueAdjuster(preciseThreshold: 10)

        XCTAssertEqual(
            adjuster.value(
                afterScrolling: 1,
                isPrecise: false,
                currentValue: 40,
                range: 0...100,
                step: 1,
                isEnabled: true
            ),
            41
        )
        XCTAssertEqual(
            adjuster.value(
                afterScrolling: -1,
                isPrecise: false,
                currentValue: 41,
                range: 0...100,
                step: 1,
                isEnabled: true
            ),
            40
        )
    }

    func testDiscreteWheelIgnoresDeltaMagnitudeAndSnapsFromRangeLowerBound() {
        var adjuster = ScrollWheelValueAdjuster(preciseThreshold: 10)

        XCTAssertEqual(
            adjuster.value(
                afterScrolling: 2,
                isPrecise: false,
                currentValue: 10.25,
                range: 10...20,
                step: 0.25,
                isEnabled: true
            ),
            10.5,
            accuracy: 0.000_001
        )
    }

    func testWheelValueIsClampedToRange() {
        var adjuster = ScrollWheelValueAdjuster(preciseThreshold: 10)

        XCTAssertEqual(
            adjuster.value(
                afterScrolling: 2,
                isPrecise: false,
                currentValue: 99,
                range: 0...100,
                step: 1,
                isEnabled: true
            ),
            100
        )
        XCTAssertEqual(
            adjuster.value(
                afterScrolling: -2,
                isPrecise: false,
                currentValue: 1,
                range: 0...100,
                step: 1,
                isEnabled: true
            ),
            0
        )
    }

    func testPreciseWheelAccumulatesAndCanCrossMultipleThresholds() {
        var adjuster = ScrollWheelValueAdjuster(preciseThreshold: 10)

        XCTAssertEqual(
            adjuster.value(
                afterScrolling: 4,
                isPrecise: true,
                currentValue: 50,
                range: 0...100,
                step: 1,
                isEnabled: true
            ),
            50
        )
        XCTAssertEqual(
            adjuster.value(
                afterScrolling: 7,
                isPrecise: true,
                currentValue: 50,
                range: 0...100,
                step: 1,
                isEnabled: true
            ),
            51
        )
        XCTAssertEqual(
            adjuster.value(
                afterScrolling: 21,
                isPrecise: true,
                currentValue: 51,
                range: 0...100,
                step: 1,
                isEnabled: true
            ),
            53
        )
    }

    func testPreciseWheelDropsRemainderWhenDirectionReverses() {
        var adjuster = ScrollWheelValueAdjuster(preciseThreshold: 10)

        XCTAssertEqual(
            adjuster.value(
                afterScrolling: 8,
                isPrecise: true,
                currentValue: 50,
                range: 0...100,
                step: 1,
                isEnabled: true
            ),
            50
        )
        XCTAssertEqual(
            adjuster.value(
                afterScrolling: -3,
                isPrecise: true,
                currentValue: 50,
                range: 0...100,
                step: 1,
                isEnabled: true
            ),
            50
        )
        XCTAssertEqual(
            adjuster.value(
                afterScrolling: -7,
                isPrecise: true,
                currentValue: 50,
                range: 0...100,
                step: 1,
                isEnabled: true
            ),
            49
        )
    }

    func testDisabledWheelDoesNotChangeValueOrAccumulate() {
        var adjuster = ScrollWheelValueAdjuster(preciseThreshold: 10)

        XCTAssertEqual(
            adjuster.value(
                afterScrolling: 9,
                isPrecise: true,
                currentValue: 50,
                range: 0...100,
                step: 1,
                isEnabled: false
            ),
            50
        )
        XCTAssertEqual(
            adjuster.value(
                afterScrolling: 1,
                isPrecise: true,
                currentValue: 50,
                range: 0...100,
                step: 1,
                isEnabled: true
            ),
            50
        )
    }

    func testNativeSliderConsumesVerticalWheelAndSendsAction() throws {
        let probe = SliderActionProbe()
        let slider = ScrollWheelNSSlider(
            value: 40,
            minValue: 0,
            maxValue: 100,
            target: probe,
            action: #selector(SliderActionProbe.valueChanged(_:))
        )
        slider.wheelStep = 1

        let cgEvent = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 1,
                wheel1: 1,
                wheel2: 0,
                wheel3: 0
            )
        )
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))

        slider.scrollWheel(with: event)

        XCTAssertEqual(slider.doubleValue, 41)
        XCTAssertEqual(probe.receivedValue, 41)
    }

    func testNativeSliderRequestsExpansionWhenScrollingAboveMaximum() throws {
        let slider = ScrollWheelNSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
        var expansionCount = 0
        slider.onRequestRangeExpansion = { expansionCount += 1 }

        let cgEvent = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 1,
                wheel1: 1,
                wheel2: 0,
                wheel3: 0
            )
        )
        slider.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cgEvent)))

        XCTAssertEqual(expansionCount, 1)
        XCTAssertEqual(slider.doubleValue, 100)
    }

    func testNativeSliderDropsPreciseRemainderWhileDisabled() throws {
        let probe = SliderActionProbe()
        let slider = ScrollWheelNSSlider(
            value: 40,
            minValue: 0,
            maxValue: 100,
            target: probe,
            action: #selector(SliderActionProbe.valueChanged(_:))
        )
        slider.wheelStep = 1

        slider.scrollWheel(with: try preciseScrollEvent(delta: 9))
        slider.isEnabled = false
        slider.scrollWheel(with: try preciseScrollEvent(delta: 1))
        slider.isEnabled = true
        slider.scrollWheel(with: try preciseScrollEvent(delta: 1))

        XCTAssertEqual(slider.doubleValue, 40)
        XCTAssertNil(probe.receivedValue)
    }
}

private final class SliderActionProbe: NSObject {
    private(set) var receivedValue: Double?

    @objc func valueChanged(_ sender: NSSlider) {
        receivedValue = sender.doubleValue
    }
}

private func preciseScrollEvent(delta: Int32) throws -> NSEvent {
    let cgEvent = try XCTUnwrap(
        CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: delta,
            wheel2: 0,
            wheel3: 0
        )
    )
    let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
    XCTAssertTrue(event.hasPreciseScrollingDeltas)
    return event
}
