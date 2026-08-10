import CoreGraphics
import Foundation

struct DisplayColorPresetOption: Codable, Equatable, Identifiable, Sendable {
    var id: UInt8 { rawValue }
    var rawValue: UInt8
    var name: String
}

enum DisplayColorPresetStatus: String, Codable, Sendable {
    case available
    case unavailable
    case unsupported
}

struct DisplayColorPresetCapability: Codable, Equatable, Sendable {
    var status: DisplayColorPresetStatus
    var currentRawValue: UInt8?
    var options: [DisplayColorPresetOption]
    var advertisedRawValues: [UInt8]
    var unavailableReason: String?
}

struct DisplayColorPresetWriteResult: Equatable, Sendable {
    var displayID: CGDirectDisplayID
    var requestedRawValue: UInt8
    var verifiedRawValue: UInt8
    var verifiedAt: Date
}

struct DisplayColorPresetVerificationPolicy: Sendable {
    var initialDelayNanos: UInt64
    var retryDelayNanos: UInt64
    var maximumReadAttempts: Int
    /// Number of Set VCP attempts before reporting a transport failure.
    /// DDPM's `-[DDCCtl(ReadWrite) Set:::]` retries the write up to 3 times.
    var maximumWriteAttempts: Int = 3
    /// Delay between failed write attempts (defaults to none, like DDPM).
    var writeRetryDelayNanos: UInt64 = 0

    static let poc = DisplayColorPresetVerificationPolicy(
        initialDelayNanos: 500_000_000,
        retryDelayNanos: 500_000_000,
        maximumReadAttempts: 5
    )
}

enum DisplayColorPresetError: Error, Equatable, LocalizedError {
    case providerUnsupported
    case capabilityUnavailable
    case presetNotAdvertised
    case valueNotAdvertised(UInt8)
    case transportWriteFailed
    case readbackFailed
    case verificationMismatch(requested: UInt8, lastObserved: UInt8?)

    var errorDescription: String? {
        switch self {
        case .providerUnsupported:
            return "Color preset control is unavailable from this display provider."
        case .capabilityUnavailable:
            return "The display capability report is unavailable."
        case .presetNotAdvertised:
            return "The display did not advertise color preset control."
        case let .valueNotAdvertised(value):
            return String(format: "Preset 0x%02X was not advertised by this display.", value)
        case .transportWriteFailed:
            return "The display rejected the color preset write."
        case .readbackFailed:
            return "The color preset could not be read back."
        case let .verificationMismatch(requested, lastObserved):
            let actual = lastObserved.map { String(format: "0x%02X", $0) } ?? "unknown"
            return String(
                format: "Preset 0x%02X was requested, but the display reported %@.",
                requested,
                actual
            )
        }
    }
}
