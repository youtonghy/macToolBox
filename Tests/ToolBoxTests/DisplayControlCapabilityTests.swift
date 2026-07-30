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
        let report = try DDCCapabilityParser.parse(
            "prot(monitor)type(lcd)vcp(02 04 10 12 14(00 01 08 0b 0c) 16 18 1a 60(01 0f 11) 62)"
        ).get()

        XCTAssertEqual(report.supportedVCPs, [0x02, 0x04, 0x10, 0x12, 0x14, 0x16, 0x18, 0x1A, 0x60, 0x62])
        XCTAssertEqual(report.enumValues[0x14], [0x00, 0x01, 0x08, 0x0B, 0x0C])
        XCTAssertEqual(report.enumValues[0x60], [0x01, 0x0F, 0x11])
    }

    func testCapabilityParserPreservesUnknownPresetValues() throws {
        let report = try DDCCapabilityParser.parse(
            "prot(monitor)vcp(10 14(0B 41 A7) 60(01 0F))"
        ).get()

        XCTAssertEqual(report.enumValues[0x14], [0x0B, 0x41, 0xA7])
    }

    func testCapabilityParserDistinguishesMissingAndEmptyPresetSubset() throws {
        let noPreset = try DDCCapabilityParser.parse("vcp(10 12 60(01))").get()
        XCTAssertEqual(noPreset.support(for: 0x14), .notAdvertised)

        let emptyPreset = try DDCCapabilityParser.parse("vcp(10 12 14 60(01))").get()
        XCTAssertEqual(emptyPreset.support(for: 0x14), .advertisedNoEnumSubset)
    }

    func testCapabilityParserRejectsTruncatedOrInvalidVCPBlocks() {
        XCTAssertEqual(
            DDCCapabilityParser.parse("prot(monitor)vcp(10 14(0B 41)"),
            .failure(.unterminatedVCPBlock)
        )
        XCTAssertEqual(
            DDCCapabilityParser.parse("vcp(10 14(0B ZZ))"),
            .failure(.invalidHexToken("ZZ"))
        )
        XCTAssertEqual(
            DDCCapabilityParser.parse("vcp(10 14(0B(41)))"),
            .failure(.invalidNesting)
        )
    }

    func testCapabilityParserFailsClosedWhenVCPBlockIsMissing() {
        XCTAssertEqual(
            DDCCapabilityParser.parse("prot(monitor)type(lcd)"),
            .failure(.missingVCPBlock)
        )
    }

    func testCapabilityBlockParsesPayloadAndOffset() throws {
        let bytes = capabilityBlock(offset: 0x0123, payload: Array("vcp(10)".utf8))
        let block = try DDCCapabilityBlockParser.parse(bytes, expectedOffset: 0x0123).get()

        XCTAssertEqual(block.offset, 0x0123)
        XCTAssertEqual(block.payload, Array("vcp(10)".utf8))
        XCTAssertFalse(block.isTerminator)
    }

    func testCapabilityBlockAcceptsZeroLengthTerminator() throws {
        let block = try DDCCapabilityBlockParser.parse(
            capabilityBlock(offset: 8, payload: []),
            expectedOffset: 8
        ).get()

        XCTAssertTrue(block.isTerminator)
    }

    func testCapabilityBlockRejectsLengthPastBuffer() {
        var bytes = capabilityBlock(offset: 0, payload: [])
        bytes[1] = 0xFF

        XCTAssertEqual(
            DDCCapabilityBlockParser.parse(bytes, expectedOffset: 0),
            .failure(.invalidBlock)
        )
    }

    func testCapabilityBlockRejectsChecksumMismatch() {
        var bytes = capabilityBlock(offset: 0, payload: Array("abc".utf8))
        bytes[8] ^= 0xFF

        XCTAssertEqual(
            DDCCapabilityBlockParser.parse(bytes, expectedOffset: 0),
            .failure(.invalidBlock)
        )
    }

    func testCapabilityBlockRejectsUnexpectedOffset() {
        XCTAssertEqual(
            DDCCapabilityBlockParser.parse(
                capabilityBlock(offset: 5, payload: Array("abc".utf8)),
                expectedOffset: 4
            ),
            .failure(.unexpectedOffset(expected: 4, actual: 5))
        )
    }

    func testCapabilityStringAssemblerRejectsNonASCIIAndOversizedOutput() {
        XCTAssertEqual(
            DDCCapabilityStringAssembler.assemble { offset in
                offset == 0
                    ? self.capabilityBlock(offset: 0, payload: [0xFF])
                    : self.capabilityBlock(offset: 1, payload: [])
            },
            .failure(.invalidASCII)
        )

        XCTAssertEqual(
            DDCCapabilityStringAssembler.assemble { offset in
                self.capabilityBlock(offset: offset, payload: [UInt8](repeating: 0x41, count: 44))
            },
            .failure(.exceededMaximumLength)
        )
    }

    func testArm64CapabilitySequenceBuildsRequestsAndAssemblesBlocks() throws {
        var requests: [[UInt8]] = []
        var readLengths: [Int] = []
        var sleeps: [UInt32] = []
        var replies = [
            capabilityBlock(offset: 0, payload: Array("vcp(".utf8)),
            capabilityBlock(offset: 4, payload: Array("10)".utf8)),
            capabilityBlock(offset: 7, payload: []),
        ]
        let backend = Arm64DDCBackend(
            backendName: "test",
            connectionToken: 42,
            writeI2C: {
                requests.append($0)
                return true
            },
            readI2C: {
                readLengths.append($0)
                return replies.removeFirst()
            },
            sleepMicros: { sleeps.append($0) }
        )

        XCTAssertEqual(try backend.readCapabilityString(options: .probe).get(), "vcp(10)")
        XCTAssertEqual(
            requests,
            [
                [0x83, 0xF3, 0x00, 0x00, 0x4F],
                [0x83, 0xF3, 0x00, 0x04, 0x4B],
                [0x83, 0xF3, 0x00, 0x07, 0x48],
            ]
        )
        XCTAssertEqual(readLengths, [50, 50, 50])
        XCTAssertEqual(sleeps, [60_000, 60_000, 60_000])
    }

    func testArm64CapabilitySequenceRetriesSameOffset() throws {
        var requests: [[UInt8]] = []
        var replies: [[UInt8]?] = [
            nil,
            capabilityBlock(offset: 0, payload: Array("abc".utf8)),
            capabilityBlock(offset: 3, payload: []),
        ]
        let backend = Arm64DDCBackend(
            backendName: "test",
            connectionToken: 7,
            writeI2C: {
                requests.append($0)
                return true
            },
            readI2C: { _ in replies.removeFirst() },
            sleepMicros: { _ in }
        )

        XCTAssertEqual(try backend.readCapabilityString(options: .probe).get(), "abc")
        XCTAssertEqual(requests.map { Array($0[2...3]) }, [[0x00, 0x00], [0x00, 0x00], [0x00, 0x03]])
    }

    func testArm64CapabilitySequenceStopsAfterElevenFailures() {
        var requestCount = 0
        let backend = Arm64DDCBackend(
            backendName: "test",
            connectionToken: 9,
            writeI2C: { _ in
                requestCount += 1
                return true
            },
            readI2C: { _ in nil },
            sleepMicros: { _ in }
        )

        XCTAssertEqual(
            backend.readCapabilityString(options: .probe),
            .failure(.tooManyConsecutiveFailures)
        )
        XCTAssertEqual(requestCount, 11)
    }

    func testArm64MissingConnectionTokenDoesNotAttemptCapabilityFallback() {
        var attemptedI2C = false
        let backend = Arm64DDCBackend(
            backendName: "test",
            connectionToken: nil,
            writeI2C: { _ in
                attemptedI2C = true
                return false
            },
            readI2C: { _ in
                attemptedI2C = true
                return nil
            },
            sleepMicros: { _ in }
        )

        XCTAssertEqual(
            backend.readCapabilityString(options: .probe),
            .failure(.transportFailure)
        )
        XCTAssertFalse(attemptedI2C)
    }

    func testIntelCapabilitySequenceUsesExpectedLayoutAndOffsets() throws {
        var requests: [[UInt8]] = []
        var replyLengths: [Int] = []
        var replies = [
            capabilityBlock(offset: 0, payload: Array("vcp(".utf8)),
            capabilityBlock(offset: 4, payload: Array("10)".utf8)),
            capabilityBlock(offset: 7, payload: []),
        ]
        let backend = IntelDDCBackend(
            backendName: "test",
            connectionToken: 88,
            performTransaction: { request, replyLength in
                requests.append(request)
                replyLengths.append(replyLength)
                return replies.removeFirst()
            },
            sleepMicros: { _ in }
        )

        XCTAssertEqual(try backend.readCapabilityString(options: .probe).get(), "vcp(10)")
        XCTAssertEqual(
            requests,
            [
                [0x51, 0x83, 0xF3, 0x00, 0x00, 0x4F],
                [0x51, 0x83, 0xF3, 0x00, 0x04, 0x4B],
                [0x51, 0x83, 0xF3, 0x00, 0x07, 0x48],
            ]
        )
        XCTAssertEqual(replyLengths, [50, 50, 50])
        XCTAssertEqual(IntelDDCBackend.capabilitySendAddress, 0x6E)
        XCTAssertEqual(IntelDDCBackend.capabilityReplyAddress, 0x6F)
        XCTAssertEqual(IntelDDCBackend.capabilityReplySubAddress, 0x51)
    }

    func testIntelCapabilitySequenceRetriesSameOffsetAndStopsAfterElevenFailures() {
        var requests: [[UInt8]] = []
        let backend = IntelDDCBackend(
            backendName: "test",
            connectionToken: 99,
            performTransaction: { request, _ in
                requests.append(request)
                return nil
            },
            sleepMicros: { _ in }
        )

        XCTAssertEqual(
            backend.readCapabilityString(options: .probe),
            .failure(.tooManyConsecutiveFailures)
        )
        XCTAssertEqual(requests.count, 11)
        XCTAssertTrue(requests.allSatisfy { Array($0[3...4]) == [0x00, 0x00] })
    }

    func testIntelMissingConnectionTokenSkipsCapabilityTransaction() {
        var attemptedTransaction = false
        let backend = IntelDDCBackend(
            backendName: "test",
            connectionToken: nil,
            performTransaction: { _, _ in
                attemptedTransaction = true
                return nil
            },
            sleepMicros: { _ in }
        )

        XCTAssertEqual(
            backend.readCapabilityString(options: .probe),
            .failure(.transportFailure)
        )
        XCTAssertFalse(attemptedTransaction)
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

    private func capabilityBlock(offset: UInt16, payload: [UInt8]) -> [UInt8] {
        precondition(payload.count <= 44)
        var reply = [UInt8](repeating: 0, count: 50)
        reply[0] = 0x6E
        reply[1] = 0x83 + UInt8(payload.count)
        reply[2] = 0xE3
        reply[3] = UInt8(offset >> 8)
        reply[4] = UInt8(offset & 0xFF)
        reply.replaceSubrange(5..<(5 + payload.count), with: payload)

        let checksumIndex = 5 + payload.count
        var checksum: UInt8 = 0x50
        for byte in reply[..<checksumIndex] {
            checksum ^= byte
        }
        reply[checksumIndex] = checksum
        return reply
    }
}
