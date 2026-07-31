import XCTest
@testable import ToolBox

final class FrameStabilityDetectorTests: XCTestCase {
    func testRequiresConsecutiveQuietSamples() throws {
        let configuration = ScrollMatchingConfiguration(requiredStableSamples: 2)
        var detector = FrameStabilityDetector(configuration: configuration)
        let frame = try LumaFrame(width: 4, height: 4, pixels: Array(repeating: 20, count: 16))
        let changed = try LumaFrame(width: 4, height: 4, pixels: Array(repeating: 80, count: 16))

        XCTAssertEqual(try detector.observe(frame, timestamp: 1), .moving(consecutiveQuietSamples: 0))
        XCTAssertEqual(try detector.observe(frame, timestamp: 2), .moving(consecutiveQuietSamples: 1))
        XCTAssertEqual(try detector.observe(changed, timestamp: 3), .moving(consecutiveQuietSamples: 0))
        XCTAssertEqual(try detector.observe(changed, timestamp: 4), .moving(consecutiveQuietSamples: 1))
        XCTAssertEqual(try detector.observe(changed, timestamp: 5), .stable)
    }

    func testRejectsInvalidFrameAndNonMonotonicTimestamp() throws {
        XCTAssertThrowsError(try LumaFrame(width: 2, height: 2, pixels: [1, 2, 3])) {
            XCTAssertEqual($0 as? ScrollCaptureError, .invalidLumaFrame)
        }

        var detector = FrameStabilityDetector()
        let frame = try LumaFrame(width: 2, height: 2, pixels: [1, 2, 3, 4])
        _ = try detector.observe(frame, timestamp: 10)
        XCTAssertThrowsError(try detector.observe(frame, timestamp: 9)) {
            XCTAssertEqual($0 as? ScrollCaptureError, .nonMonotonicTimestamp)
        }
    }

    func testDimensionChangeFailsBeforeComparison() throws {
        var detector = FrameStabilityDetector()
        _ = try detector.observe(
            LumaFrame(width: 2, height: 2, pixels: [1, 2, 3, 4]),
            timestamp: 1
        )
        XCTAssertThrowsError(
            try detector.observe(
                LumaFrame(width: 4, height: 1, pixels: [1, 2, 3, 4]),
                timestamp: 2
            )
        ) {
            XCTAssertEqual($0 as? ScrollCaptureError, .frameDimensionsChanged)
        }
    }
}
