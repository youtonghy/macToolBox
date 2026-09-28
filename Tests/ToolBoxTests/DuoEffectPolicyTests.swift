import XCTest
@testable import ToolBoxCore

final class DuoEffectPolicyTests: XCTestCase {
    func testRemainingIsZeroAtEndpoint() {
        XCTAssertEqual(
            DuoEffectPolicy.remaining(angle: 120, velocity: 0, endpoint: 120, preview: false),
            0
        )
    }

    func testRemainingIsOneAtZeroAngle() {
        XCTAssertEqual(
            DuoEffectPolicy.remaining(angle: 0, velocity: 0, endpoint: 120, preview: false),
            1
        )
    }

    func testRemainingClampsAboveEndpoint() {
        XCTAssertEqual(
            DuoEffectPolicy.remaining(angle: 160, velocity: 0, endpoint: 120, preview: false),
            0
        )
    }

    func testRemainingIsProportionalBetweenZeroAndEndpoint() {
        XCTAssertEqual(
            DuoEffectPolicy.remaining(angle: 60, velocity: 0, endpoint: 120, preview: false),
            0.5,
            accuracy: 0.0001
        )
    }

    func testClosingVelocityPredictsAhead() {
        // A fast closing lid (negative velocity) shows more remaining effect.
        let still = DuoEffectPolicy.remaining(angle: 110, velocity: 0, endpoint: 120, preview: false)
        let closing = DuoEffectPolicy.remaining(angle: 110, velocity: -100, endpoint: 120, preview: false)
        XCTAssertGreaterThan(closing, still)
    }

    func testOpeningVelocityDoesNotPredictBelowZero() {
        // Positive velocity prediction is clamped at 0; result matches still.
        let still = DuoEffectPolicy.remaining(angle: 110, velocity: 0, endpoint: 120, preview: false)
        let opening = DuoEffectPolicy.remaining(angle: 110, velocity: 100, endpoint: 120, preview: false)
        XCTAssertEqual(still, opening)
    }

    func testInvalidInputsReturnZero() {
        XCTAssertEqual(DuoEffectPolicy.remaining(angle: .nan, velocity: 0, endpoint: 120, preview: false), 0)
        XCTAssertEqual(DuoEffectPolicy.remaining(angle: 60, velocity: .nan, endpoint: 120, preview: false), 0)
        XCTAssertEqual(DuoEffectPolicy.remaining(angle: 60, velocity: 0, endpoint: 0, preview: false), 0)
        XCTAssertEqual(DuoEffectPolicy.remaining(angle: 60, velocity: 0, endpoint: -10, preview: false), 0)
    }

    func testPreviewRemainingIsFixed() {
        XCTAssertEqual(
            DuoEffectPolicy.remaining(angle: 150, velocity: 0, endpoint: 120, preview: true),
            0.35
        )
    }

    func testCaptureFPSStaysHighWhileEffectVisibleOrMoving() {
        XCTAssertEqual(DuoEffectPolicy.captureFPS(remaining: 0.5, velocity: 0), 30)
        XCTAssertEqual(DuoEffectPolicy.captureFPS(remaining: 0, velocity: 5), 30)
        XCTAssertEqual(DuoEffectPolicy.captureFPS(remaining: 0, velocity: -5), 30)
    }

    func testCaptureFPSDropsWhenSettled() {
        XCTAssertEqual(DuoEffectPolicy.captureFPS(remaining: 0, velocity: 0), 2)
        XCTAssertEqual(DuoEffectPolicy.captureFPS(remaining: 0.005, velocity: 1), 2)
    }

    func testRetryDelayGrowsAndCaps() {
        XCTAssertEqual(DuoEffectPolicy.retryDelay(failures: 0), 2)
        XCTAssertEqual(DuoEffectPolicy.retryDelay(failures: 1), 2)
        XCTAssertEqual(DuoEffectPolicy.retryDelay(failures: 5), 10)
        XCTAssertEqual(DuoEffectPolicy.retryDelay(failures: 100), 30)
    }
}

final class LidAngleSensorDecodeTests: XCTestCase {
    func testDecodesLittleEndianAngle() {
        // report[0] = report id, report[1...2] = little-endian degrees.
        let report: [UInt8] = [1, 105, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(LidAngleSensor.decodeAngle(report: report, reportLength: 8), 105)
    }

    func testDecodesZeroAndMaxAngle() {
        XCTAssertEqual(
            LidAngleSensor.decodeAngle(report: [1, 0, 0], reportLength: 3),
            0
        )
        XCTAssertEqual(
            LidAngleSensor.decodeAngle(report: [1, 180, 0], reportLength: 3),
            180
        )
    }

    func testHundredthsDegreeReportsAreScaledDown() {
        // 10500 hundredths (0x2904 little-endian) -> 105 degrees.
        let report: [UInt8] = [1, 0x04, 0x29]
        XCTAssertEqual(LidAngleSensor.decodeAngle(report: report, reportLength: 3), 105)
    }

    func testRejectsShortReports() {
        XCTAssertNil(LidAngleSensor.decodeAngle(report: [1, 90], reportLength: 2))
        XCTAssertNil(LidAngleSensor.decodeAngle(report: [], reportLength: 0))
    }

    func testRejectsOutOfRangeAngles() {
        // 181 raw is out of range and below the hundredths threshold.
        XCTAssertNil(LidAngleSensor.decodeAngle(report: [1, 181, 0], reportLength: 3))
        // 36001 hundredths -> 360.01 degrees, still out of range.
        XCTAssertNil(LidAngleSensor.decodeAngle(report: [1, 0xA1, 0x8C], reportLength: 3))
    }
}
