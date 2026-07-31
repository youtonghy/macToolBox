import CoreGraphics
import XCTest
@testable import ToolBox

final class FrozenCaptureBudgetTests: XCTestCase {
    func testAggregateBytesAtLimitIsAccepted() throws {
        XCTAssertNoThrow(try FrozenCaptureBudget.validate(
            pixelSizes: [CGSize(width: 12_288, height: 16_384)]
        ))
    }

    func testAggregateBytesAboveLimitIsRejected() {
        XCTAssertThrowsError(try FrozenCaptureBudget.validate(
            pixelSizes: [CGSize(width: 12_288, height: 16_385)]
        )) {
            XCTAssertEqual($0 as? ScreenshotCaptureError, .frozenFrameBudgetExceeded)
        }
    }

    func testByteCountOverflowIsRejected() {
        XCTAssertThrowsError(try FrozenCaptureBudget.validate(
            pixelSizes: [CGSize(width: CGFloat.greatestFiniteMagnitude, height: 2)]
        )) {
            XCTAssertEqual($0 as? ScreenshotCaptureError, .invalidImageDimensions)
        }
    }
}
