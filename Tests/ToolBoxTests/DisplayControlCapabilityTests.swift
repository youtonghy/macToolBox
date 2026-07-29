import XCTest
@testable import ToolBox

final class DisplayControlCapabilityTests: XCTestCase {
    func testWriteOnlyControlsRemainWritable() {
        XCTAssertTrue(DisplayControlStatus.available.isWritable)
        XCTAssertTrue(DisplayControlStatus.writeOnly.isWritable)
        XCTAssertFalse(DisplayControlStatus.unavailable.isWritable)
        XCTAssertFalse(DisplayControlStatus.unsupported.isWritable)
    }

    func testArm64ReadFailureDoesNotReuseSuccessfulWriteResult() {
        XCTAssertFalse(
            Arm64DDCBackend.communicationSucceeded(
                writeSucceeded: true,
                expectsReply: true,
                readSucceeded: false,
                replyChecksumIsValid: false
            )
        )
        XCTAssertFalse(
            Arm64DDCBackend.communicationSucceeded(
                writeSucceeded: false,
                expectsReply: true,
                readSucceeded: true,
                replyChecksumIsValid: true
            )
        )
        XCTAssertFalse(
            Arm64DDCBackend.communicationSucceeded(
                writeSucceeded: true,
                expectsReply: true,
                readSucceeded: true,
                replyChecksumIsValid: false
            )
        )
        XCTAssertTrue(
            Arm64DDCBackend.communicationSucceeded(
                writeSucceeded: true,
                expectsReply: true,
                readSucceeded: true,
                replyChecksumIsValid: true
            )
        )
        XCTAssertTrue(
            Arm64DDCBackend.communicationSucceeded(
                writeSucceeded: true,
                expectsReply: false,
                readSucceeded: false,
                replyChecksumIsValid: false
            )
        )
    }
}
