import XCTest
@testable import ToolBox

final class DisplayControlCapabilityTests: XCTestCase {
    func testWriteOnlyControlsRemainWritable() {
        XCTAssertTrue(DisplayControlStatus.available.isWritable)
        XCTAssertTrue(DisplayControlStatus.writeOnly.isWritable)
        XCTAssertFalse(DisplayControlStatus.unavailable.isWritable)
        XCTAssertFalse(DisplayControlStatus.unsupported.isWritable)
    }
}
