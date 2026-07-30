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

    static let poc = DisplayColorPresetVerificationPolicy(
        initialDelayNanos: 200_000_000,
        retryDelayNanos: 200_000_000,
        maximumReadAttempts: 3
    )
}

enum DisplayColorPresetError: Error, Equatable, LocalizedError {
    case providerUnsupported
    case capabilityUnavailable
    case presetNotAdvertised
    case unverifiedDisplayIdentity
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
        case .unverifiedDisplayIdentity:
            return "This display identity has no verified color preset mapping."
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

struct DisplayColorPresetCatalogEntry: Equatable, Sendable {
    var identity: DisplayHardwareIdentity
    var options: [DisplayColorPresetOption]
}

struct DisplayColorPresetCatalog: Sendable {
    static let production = DisplayColorPresetCatalog(entries: [])

    private let entries: [DisplayHardwareIdentity: [DisplayColorPresetOption]]

    init(entries: [DisplayColorPresetCatalogEntry]) {
        var indexedEntries: [DisplayHardwareIdentity: [DisplayColorPresetOption]] = [:]
        for entry in entries {
            indexedEntries[entry.identity] = entry.options
        }
        self.entries = indexedEntries
    }

    func options(
        identity: DisplayHardwareIdentity,
        advertisedValues: Set<UInt8>
    ) -> [DisplayColorPresetOption] {
        guard let verifiedOptions = entries[identity] else {
            return []
        }
        return verifiedOptions.filter { advertisedValues.contains($0.rawValue) }
    }

    func contains(identity: DisplayHardwareIdentity) -> Bool {
        entries[identity] != nil
    }

    func authorizes(identity: DisplayHardwareIdentity, rawValue: UInt8) -> Bool {
        entries[identity]?.contains { $0.rawValue == rawValue } == true
    }
}
