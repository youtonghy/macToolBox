import Foundation

struct DDCReadResult: Equatable {
    var current: UInt16
    var maximum: UInt16
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

    func read(command: UInt8, options: DDCRequestOptions) -> DDCReadResult?
    func write(command: UInt8, value: UInt16, options: DDCRequestOptions) -> Bool
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
