import Foundation

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

    func readOutcome(command: UInt8, options: DDCRequestOptions) -> DDCReadOutcome
    func write(command: UInt8, value: UInt16, options: DDCRequestOptions) -> Bool
}

extension DDCTransport {
    func read(command: UInt8, options: DDCRequestOptions) -> DDCReadResult? {
        guard case let .success(result) = readOutcome(command: command, options: options) else {
            return nil
        }
        return result
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
