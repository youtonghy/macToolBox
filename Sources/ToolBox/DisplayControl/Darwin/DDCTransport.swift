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

struct DDCCapabilityReport: Equatable, Sendable {
    let supportedVCPs: Set<UInt8>
    let presetValues: Set<UInt8>
    let inputSources: Set<UInt8>
    let rawString: String
}

enum DDCCapabilityParser {
    static func parse(_ raw: String) -> DDCCapabilityReport? {
        guard let range = raw.range(of: "vcp(", options: [.caseInsensitive]) else {
            return nil
        }

        let bytes = Array(raw[range.upperBound...].utf8)
        var supportedVCPs = Set<UInt8>()
        var presetValues = Set<UInt8>()
        var inputSources = Set<UInt8>()
        var index = 0

        while index < bytes.count {
            skipWhitespace(in: bytes, index: &index)
            if index >= bytes.count || bytes[index] == 0x29 {
                break
            }

            let codeStart = index
            while index < bytes.count, isHexDigit(bytes[index]) {
                index += 1
            }
            guard index > codeStart else {
                return nil
            }

            let token = String(decoding: bytes[codeStart..<index], as: UTF8.self)
            guard let code = UInt8(token, radix: 16) else {
                return nil
            }
            supportedVCPs.insert(code)

            skipWhitespace(in: bytes, index: &index)
            guard index < bytes.count else {
                break
            }
            guard bytes[index] == 0x28 else {
                continue
            }

            let valueStart = index + 1
            index += 1
            var depth = 1
            while index < bytes.count, depth > 0 {
                if bytes[index] == 0x28 {
                    depth += 1
                } else if bytes[index] == 0x29 {
                    depth -= 1
                }
                index += 1
            }
            guard depth == 0 else {
                return nil
            }

            let valueEnd = index - 1
            let values = parseHexValues(Array(bytes[valueStart..<valueEnd]))
            if code == 0x14 {
                presetValues.formUnion(values)
            } else if code == 0x60 {
                inputSources.formUnion(values)
            }
        }

        guard !supportedVCPs.isEmpty else {
            return nil
        }
        return DDCCapabilityReport(
            supportedVCPs: supportedVCPs,
            presetValues: presetValues,
            inputSources: inputSources,
            rawString: raw
        )
    }

    private static func parseHexValues(_ bytes: [UInt8]) -> Set<UInt8> {
        let text = String(decoding: bytes, as: UTF8.self)
        return Set(
            text.split(whereSeparator: \.isWhitespace).compactMap {
                UInt8($0, radix: 16)
            }
        )
    }

    private static func skipWhitespace(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 ||
            bytes[index] == 0x0A || bytes[index] == 0x0D {
            index += 1
        }
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) ||
            (byte >= 0x41 && byte <= 0x46) ||
            (byte >= 0x61 && byte <= 0x66)
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
