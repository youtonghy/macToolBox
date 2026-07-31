import XCTest
@testable import ToolBox

final class ScrollCaptureResourceBudgetTests: XCTestCase {
    func testHeightLimitOneRowBeforeAtAndAfter() throws {
        let budget = ScrollCaptureResourceBudget(maximumHeight: 60_000, maximumRGBABytes: 512 * 1_024 * 1_024)

        XCTAssertEqual(
            try budget.validateAppend(width: 100, currentHeight: 59_998, additionalRows: 1).height,
            59_999
        )
        XCTAssertEqual(
            try budget.validateAppend(width: 100, currentHeight: 59_999, additionalRows: 1).height,
            60_000
        )
        XCTAssertThrowsError(
            try budget.validateAppend(width: 100, currentHeight: 60_000, additionalRows: 1)
        ) {
            XCTAssertEqual($0 as? ScrollCaptureError, .resourceLimitReached)
        }
    }

    func testByteLimitAndOverflowAreRejected() {
        let budget = ScrollCaptureResourceBudget(maximumHeight: Int.max, maximumRGBABytes: 1_000)
        XCTAssertThrowsError(try budget.validateAppend(width: 100, currentHeight: 2, additionalRows: 1)) {
            XCTAssertEqual($0 as? ScrollCaptureError, .resourceLimitReached)
        }
        XCTAssertThrowsError(try budget.validateAppend(width: Int.max, currentHeight: 1, additionalRows: 1)) {
            XCTAssertEqual($0 as? ScrollCaptureError, .resourceLimitReached)
        }
    }

    func testInvalidDimensionsAreRejected() {
        XCTAssertThrowsError(
            try ScrollCaptureResourceBudget().validateAppend(width: 0, currentHeight: 0, additionalRows: 1)
        ) {
            XCTAssertEqual($0 as? ScrollCaptureError, .invalidStrip)
        }
    }
}
