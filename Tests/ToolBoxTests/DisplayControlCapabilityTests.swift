import XCTest
@testable import ToolBox

final class DisplayControlCapabilityTests: XCTestCase {
    func testGetVCPReplyParserUsesStatusEchoAndCurrentOffsets() {
        let reply = featureReply(command: 0x10, maximum: 100, current: 75)

        XCTAssertEqual(
            DDCFeatureReplyParser.parse(reply, expectedCommand: 0x10),
            .success(DDCReadResult(current: 75, maximum: 100, valueType: 0))
        )
    }

    func testFeatureReplyParserPreservesUnsupportedResultCode() {
        let reply = featureReply(command: 0x14, resultCode: 0x01, maximum: 0, current: 0)

        XCTAssertEqual(
            DDCFeatureReplyParser.parse(reply, expectedCommand: 0x14),
            .failure(.unsupportedReply(resultCode: 0x01))
        )
    }

    func testFeatureReplyParserSeparatesMalformedChecksumAndEcho() {
        var checksumFailure = featureReply(command: 0x10, maximum: 100, current: 75)
        checksumFailure[10] ^= 0xFF

        XCTAssertEqual(
            DDCFeatureReplyParser.parse(checksumFailure, expectedCommand: 0x10),
            .failure(.checksumMismatch)
        )

        let echoFailure = featureReply(command: 0x12, maximum: 100, current: 75)
        XCTAssertEqual(
            DDCFeatureReplyParser.parse(echoFailure, expectedCommand: 0x10),
            .failure(.unexpectedCommand(expected: 0x10, actual: 0x12))
        )
    }

    func testFeatureReplyParserPreservesInvalidSentinel() {
        let reply = featureReply(command: 0x10, maximum: 0xFFFF, current: 0xFFFF)
        XCTAssertEqual(
            DDCFeatureReplyParser.parse(reply, expectedCommand: 0x10),
            .failure(.invalidSentinel)
        )
    }

    func testCapabilityParserExtractsPresetAndInputSubsets() throws {
        let report = try XCTUnwrap(
            DDCCapabilityParser.parse(
                "prot(monitor)type(lcd)vcp(02 04 10 12 14(00 01 08 0b 0c) 16 18 1a 60(01 0f 11) 62)"
            )
        )

        XCTAssertEqual(report.supportedVCPs, [0x02, 0x04, 0x10, 0x12, 0x14, 0x16, 0x18, 0x1A, 0x60, 0x62])
        XCTAssertEqual(report.presetValues, [0x00, 0x01, 0x08, 0x0B, 0x0C])
        XCTAssertEqual(report.inputSources, [0x01, 0x0F, 0x11])
    }

    func testCapabilityParserFailsClosedWhenVCPBlockIsMissing() {
        XCTAssertNil(DDCCapabilityParser.parse("prot(monitor)type(lcd)"))
    }

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

    private func featureReply(
        command: UInt8,
        resultCode: UInt8 = 0,
        valueType: UInt8 = 0,
        maximum: UInt16,
        current: UInt16
    ) -> [UInt8] {
        var reply: [UInt8] = [
            0x6E, 0x88, 0x02, resultCode, command, valueType,
            UInt8(maximum >> 8), UInt8(maximum & 0xFF),
            UInt8(current >> 8), UInt8(current & 0xFF), 0
        ]
        var checksum: UInt8 = 0x50
        for byte in reply[0...9] {
            checksum ^= byte
        }
        reply[10] = checksum
        return reply
    }
}
