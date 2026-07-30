import Foundation

enum DDCDiagnostics {
    static func hex(_ value: UInt8) -> String {
        String(format: "0x%02X", value)
    }

    static func hex(_ value: UInt16) -> String {
        String(format: "0x%04X", value)
    }

    static func bytes(_ values: [UInt8]?) -> String {
        guard let values else { return "transport-failure" }
        return values.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    static func identity(_ identity: DisplayHardwareIdentity) -> String {
        [
            "vendor=\(identity.vendorNumber.map { String(format: "0x%08X", $0) } ?? "unknown")",
            "model=\(identity.modelNumber.map { String(format: "0x%08X", $0) } ?? "unknown")",
            "serial=\(identity.serialNumber.map { String(format: "0x%08X", $0) } ?? "unknown")",
        ].joined(separator: " ")
    }

    static func outcome(_ outcome: DDCReadOutcome) -> String {
        switch outcome {
        case .success(let result):
            return "success current=\(hex(result.current)) maximum=\(hex(result.maximum))"
        case .failure(let failure):
            return "failure=\(String(describing: failure))"
        }
    }
}

struct DDCReadResult: Equatable {
    var current: UInt16
    var maximum: UInt16
    var valueType: UInt8?

    init(current: UInt16, maximum: UInt16, valueType: UInt8? = nil) {
        self.current = current
        self.maximum = maximum
        self.valueType = valueType
    }
}

struct DDCRequestOptions {
    var readAttempts: UInt
    var writeSleepMicros: UInt32
    var writeCycles: UInt8
    var minReplyDelayMicros: UInt64?
    var errorRecoveryWaitMicros: UInt32?

    static let probe = DDCRequestOptions(
        readAttempts: 1,
        writeSleepMicros: 10_000,
        writeCycles: 1,
        minReplyDelayMicros: nil,
        errorRecoveryWaitMicros: nil
    )

    static let interactive = DDCRequestOptions(
        readAttempts: 3,
        writeSleepMicros: 10_000,
        writeCycles: 2,
        minReplyDelayMicros: nil,
        errorRecoveryWaitMicros: 2_000
    )
}

protocol DDCTransport: AnyObject {
    var backendName: String { get }
    var connectionToken: UInt64? { get }

    func readOutcome(command: UInt8, options: DDCRequestOptions) -> DDCReadOutcome
    func readCapabilityString(options: DDCRequestOptions) -> Result<String, DDCCapabilityReadFailure>
    func write(command: UInt8, value: UInt16, options: DDCRequestOptions) -> Bool
}

extension DDCTransport {
    var connectionToken: UInt64? { nil }

    func read(command: UInt8, options: DDCRequestOptions) -> DDCReadResult? {
        guard case let .success(result) = readOutcome(command: command, options: options) else {
            return nil
        }
        return result
    }

    func readCapabilityString(options _: DDCRequestOptions) -> Result<String, DDCCapabilityReadFailure> {
        .failure(.transportFailure)
    }
}

enum DDCReadOutcome: Equatable {
    case success(DDCReadResult)
    case failure(DDCReadFailure)
}

enum DDCReadFailure: Error, Equatable {
    case unsupportedReply(resultCode: UInt8)
    case invalidSentinel
    case checksumMismatch
    case malformedReply
    case unexpectedCommand(expected: UInt8, actual: UInt8)
    case transportFailure
}

enum DDCFeatureReplyParser {
    static func parse(_ bytes: [UInt8], expectedCommand: UInt8) -> DDCReadOutcome {
        guard bytes.count == 11 else {
            return .failure(.malformedReply)
        }
        guard bytes[0] == 0x6E else {
            return .failure(.malformedReply)
        }
        guard bytes[1] == 0x88, bytes[2] == 0x02 else {
            return .failure(.malformedReply)
        }

        var checksum: UInt8 = 0x50
        for byte in bytes.dropLast() {
            checksum ^= byte
        }
        guard checksum == bytes.last else {
            return .failure(.checksumMismatch)
        }

        guard bytes[4] == expectedCommand else {
            return .failure(.unexpectedCommand(expected: expectedCommand, actual: bytes[4]))
        }
        guard bytes[3] == 0 else {
            return .failure(.unsupportedReply(resultCode: bytes[3]))
        }

        let maximum = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        let current = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        guard maximum != .max || current != .max else {
            return .failure(.invalidSentinel)
        }
        return .success(
            DDCReadResult(
                current: current,
                maximum: maximum,
                valueType: bytes[5]
            )
        )
    }
}

struct DDCCapabilityBlock: Equatable {
    var offset: UInt16
    var payload: [UInt8]

    var isTerminator: Bool { payload.isEmpty }
}

enum DDCCapabilityReadFailure: Error, Equatable {
    case transportFailure
    case invalidBlock
    case unexpectedOffset(expected: UInt16, actual: UInt16)
    case invalidASCII
    case exceededMaximumLength
    case tooManyConsecutiveFailures
}

enum DDCCapabilityBlockParser {
    static let readBufferLength = 50

    static func parse(
        _ bytes: [UInt8],
        expectedOffset: UInt16
    ) -> Result<DDCCapabilityBlock, DDCCapabilityReadFailure> {
        guard bytes.count == readBufferLength,
              bytes[0] == 0x6E,
              bytes[2] == 0xE3 else {
            return .failure(.invalidBlock)
        }

        let encodedLength = Int(bytes[1] & 0x7F)
        guard bytes[1] & 0x80 != 0, encodedLength >= 3 else {
            return .failure(.invalidBlock)
        }

        let payloadLength = encodedLength - 3
        let checksumIndex = 5 + payloadLength
        guard checksumIndex < bytes.count else {
            return .failure(.invalidBlock)
        }

        var checksum: UInt8 = 0x50
        for byte in bytes[..<checksumIndex] {
            checksum ^= byte
        }
        guard checksum == bytes[checksumIndex] else {
            return .failure(.invalidBlock)
        }

        let actualOffset = UInt16(bytes[3]) << 8 | UInt16(bytes[4])
        guard actualOffset == expectedOffset else {
            return .failure(.unexpectedOffset(expected: expectedOffset, actual: actualOffset))
        }

        return .success(
            DDCCapabilityBlock(
                offset: actualOffset,
                payload: Array(bytes[5..<checksumIndex])
            )
        )
    }
}

enum DDCCapabilityStringAssembler {
    static let maximumLength = 16_384
    static let maximumConsecutiveFailures = 10

    static func assemble(
        readBlock: (_ expectedOffset: UInt16) -> [UInt8]?
    ) -> Result<String, DDCCapabilityReadFailure> {
        var bytes: [UInt8] = []
        var expectedOffset: UInt16 = 0
        var consecutiveFailures = 0

        while true {
            let parseResult = readBlock(expectedOffset).map {
                DDCCapabilityBlockParser.parse($0, expectedOffset: expectedOffset)
            }

            guard let parseResult else {
                consecutiveFailures += 1
                if consecutiveFailures > maximumConsecutiveFailures {
                    return .failure(.tooManyConsecutiveFailures)
                }
                continue
            }

            switch parseResult {
            case .failure:
                consecutiveFailures += 1
                if consecutiveFailures > maximumConsecutiveFailures {
                    return .failure(.tooManyConsecutiveFailures)
                }
            case .success(let block):
                consecutiveFailures = 0
                if block.isTerminator {
                    guard let string = String(bytes: bytes, encoding: .ascii) else {
                        return .failure(.invalidASCII)
                    }
                    return .success(string)
                }

                guard bytes.count + block.payload.count <= maximumLength else {
                    return .failure(.exceededMaximumLength)
                }
                bytes.append(contentsOf: block.payload)
                expectedOffset += UInt16(block.payload.count)
            }
        }
    }
}

enum DDCAdvertisedSupport: Equatable, Sendable {
    case advertisedWithSubset(Set<UInt8>)
    case advertisedNoEnumSubset
    case notAdvertised
    case capabilityStringUnavailable
}

struct DDCCapabilityReport: Equatable, Sendable {
    let supportedVCPs: Set<UInt8>
    let enumValues: [UInt8: Set<UInt8>]
    let rawString: String

    func support(for code: UInt8) -> DDCAdvertisedSupport {
        guard supportedVCPs.contains(code) else {
            return .notAdvertised
        }
        guard let values = enumValues[code] else {
            return .advertisedNoEnumSubset
        }
        return .advertisedWithSubset(values)
    }
}

enum DDCCapabilityParseFailure: Error, Equatable {
    case missingVCPBlock
    case unterminatedVCPBlock
    case invalidHexToken(String)
    case invalidNesting
}

enum DDCCapabilityParser {
    static func parse(_ raw: String) -> Result<DDCCapabilityReport, DDCCapabilityParseFailure> {
        let bytes = Array(raw.utf8)
        guard let contentStart = vcpContentStart(in: bytes) else {
            return .failure(.missingVCPBlock)
        }
        let contentEnd: Int
        switch vcpContentEnd(in: bytes, startingAt: contentStart) {
        case .success(let end):
            contentEnd = end
        case .failure(let failure):
            return .failure(failure)
        }

        var supportedVCPs = Set<UInt8>()
        var enumValues: [UInt8: Set<UInt8>] = [:]
        var index = contentStart

        while index < contentEnd {
            skipWhitespace(in: bytes, index: &index, limit: contentEnd)
            guard index < contentEnd else { break }

            switch parseHexToken(in: bytes, index: &index, limit: contentEnd) {
            case .success(let code):
                supportedVCPs.insert(code)
                skipWhitespace(in: bytes, index: &index, limit: contentEnd)
                if index < contentEnd, bytes[index] == 0x28 {
                    index += 1
                    switch parseEnumValues(in: bytes, index: &index, limit: contentEnd) {
                    case .success(let values):
                        enumValues[code, default: []].formUnion(values)
                    case .failure(let failure):
                        return .failure(failure)
                    }
                }
            case .failure(let failure):
                return .failure(failure)
            }
        }

        return .success(
            DDCCapabilityReport(
                supportedVCPs: supportedVCPs,
                enumValues: enumValues,
                rawString: raw
            )
        )
    }

    private static func vcpContentStart(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4) where
            asciiLowercase(bytes[index]) == 0x76 &&
            asciiLowercase(bytes[index + 1]) == 0x63 &&
            asciiLowercase(bytes[index + 2]) == 0x70 &&
            bytes[index + 3] == 0x28 {
            return index + 4
        }
        return nil
    }

    private static func vcpContentEnd(
        in bytes: [UInt8],
        startingAt start: Int
    ) -> Result<Int, DDCCapabilityParseFailure> {
        var depth = 1
        for index in start..<bytes.count {
            if bytes[index] == 0x28 {
                depth += 1
                guard depth <= 2 else {
                    return .failure(.invalidNesting)
                }
            } else if bytes[index] == 0x29 {
                depth -= 1
                if depth == 0 {
                    return .success(index)
                }
            }
        }
        return .failure(.unterminatedVCPBlock)
    }

    private static func parseEnumValues(
        in bytes: [UInt8],
        index: inout Int,
        limit: Int
    ) -> Result<Set<UInt8>, DDCCapabilityParseFailure> {
        var values = Set<UInt8>()
        while index < limit {
            skipWhitespace(in: bytes, index: &index, limit: limit)
            guard index < limit else {
                return .failure(.unterminatedVCPBlock)
            }
            if bytes[index] == 0x29 {
                index += 1
                return .success(values)
            }
            if bytes[index] == 0x28 {
                return .failure(.invalidNesting)
            }

            switch parseHexToken(in: bytes, index: &index, limit: limit) {
            case .success(let value):
                values.insert(value)
            case .failure(let failure):
                return .failure(failure)
            }
        }
        return .failure(.unterminatedVCPBlock)
    }

    private static func parseHexToken(
        in bytes: [UInt8],
        index: inout Int,
        limit: Int
    ) -> Result<UInt8, DDCCapabilityParseFailure> {
        let start = index
        while index < limit, !isWhitespace(bytes[index]), bytes[index] != 0x28, bytes[index] != 0x29 {
            index += 1
        }
        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        guard index - start == 2,
              isHexDigit(bytes[start]),
              isHexDigit(bytes[start + 1]),
              let value = UInt8(token, radix: 16) else {
            return .failure(.invalidHexToken(token))
        }
        return .success(value)
    }

    private static func skipWhitespace(in bytes: [UInt8], index: inout Int, limit: Int) {
        while index < limit, isWhitespace(bytes[index]) {
            index += 1
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) ||
            (byte >= 0x41 && byte <= 0x46) ||
            (byte >= 0x61 && byte <= 0x66)
    }

    private static func asciiLowercase(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }
}

enum DDCVCPCommand: UInt8 {
    case luminance = 0x10
    case contrast = 0x12
    case audioSpeakerVolume = 0x62
    case audioMuteScreenBlank = 0x8D
}

extension DisplayControlKind {
    var ddcCommand: DDCVCPCommand {
        switch self {
        case .brightness:
            return .luminance
        case .contrast:
            return .contrast
        case .volume:
            return .audioSpeakerVolume
        case .mute:
            return .audioMuteScreenBlank
        }
    }
}
