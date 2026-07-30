import CoreGraphics
import Foundation

struct DisplayControlWriteOptions: OptionSet, Sendable, Equatable {
    let rawValue: Int

    static let force = DisplayControlWriteOptions(rawValue: 1 << 0)
    static let none = DisplayControlWriteOptions([])
}

protocol DisplayControlProviding: AnyObject {
    func snapshot() async throws -> DisplayControlSnapshot
    func refresh() async throws
    func readValue(displayID: CGDirectDisplayID, kind: DisplayControlKind) async throws -> DisplayControlValue
    func writeValue(
        displayID: CGDirectDisplayID,
        kind: DisplayControlKind,
        normalizedValue: Double,
        options: DisplayControlWriteOptions
    ) async throws -> DisplayControlValue
    func writeColorPreset(
        displayID: CGDirectDisplayID,
        rawValue: UInt8
    ) async throws -> DisplayColorPresetWriteResult
}

extension DisplayControlProviding {
    func writeValue(
        displayID: CGDirectDisplayID,
        kind: DisplayControlKind,
        normalizedValue: Double
    ) async throws -> DisplayControlValue {
        try await writeValue(
            displayID: displayID,
            kind: kind,
            normalizedValue: normalizedValue,
            options: .none
        )
    }

    func writeColorPreset(
        displayID: CGDirectDisplayID,
        rawValue: UInt8
    ) async throws -> DisplayColorPresetWriteResult {
        throw DisplayColorPresetError.providerUnsupported
    }
}

struct DisplayControlSnapshot: Codable, Equatable, Sendable {
    var timestamp: Date
    var displays: [DisplayControlDisplay]
}

struct DisplayControlDisplay: Codable, Equatable, Identifiable, Sendable {
    var id: CGDirectDisplayID
    var name: String
    var vendorNumber: UInt32?
    var modelNumber: UInt32?
    var serialNumber: UInt32?
    var isBuiltIn: Bool
    var isVirtual: Bool
    var supportsHardwareDDC: Bool
    var backendName: String?
    var unavailableReason: String?
    var controls: [DisplayControlCapability]
    var colorPreset: DisplayColorPresetCapability? = nil
}

enum DisplayControlKind: String, CaseIterable, Codable, Equatable, Sendable {
    case brightness
    case contrast
    case volume
    case mute

    var title: String {
        switch self {
        case .brightness:
            return "Brightness"
        case .contrast:
            return "Contrast"
        case .volume:
            return "Volume"
        case .mute:
            return "Mute"
        }
    }

    var isContinuous: Bool {
        self != .mute
    }
}

enum DisplayControlStatus: String, Codable, Equatable, Sendable {
    case available
    case writeOnly
    case unsupported
    case unavailable

    var isWritable: Bool {
        self == .available || self == .writeOnly
    }
}

struct DisplayControlCapability: Codable, Equatable, Sendable {
    var kind: DisplayControlKind
    var status: DisplayControlStatus
    var value: DisplayControlValue?
    var unavailableReason: String?
}

struct DisplayControlValue: Codable, Equatable, Sendable {
    var kind: DisplayControlKind
    var timestamp: Date
    var rawCurrent: UInt16
    var rawMinimum: UInt16
    var rawMaximum: UInt16
    var normalized: Double
}

enum DisplayControlError: Error, LocalizedError {
    case displayNotFound(CGDirectDisplayID)
    case unsupportedDisplay(CGDirectDisplayID, String)
    case unsupportedControl(DisplayControlKind)
    case backendUnavailable(CGDirectDisplayID, String)
    case invalidValue(Double)
    case invalidRange(minimum: UInt16, maximum: UInt16)
    case readFailed(CGDirectDisplayID, DisplayControlKind)
    case writeFailed(CGDirectDisplayID, DisplayControlKind)

    var errorDescription: String? {
        switch self {
        case let .displayNotFound(displayID):
            return "Display \(displayID) is not currently online."
        case let .unsupportedDisplay(displayID, reason):
            return "Display \(displayID) is not supported for hardware DDC control: \(reason)."
        case let .unsupportedControl(kind):
            return "\(kind.title) is not supported by the display control interface."
        case let .backendUnavailable(displayID, reason):
            return "Hardware DDC is unavailable for display \(displayID): \(reason)."
        case let .invalidValue(value):
            return "Display control value \(value) is outside the valid 0...1 range."
        case let .invalidRange(minimum, maximum):
            return "Invalid DDC range: minimum \(minimum), maximum \(maximum)."
        case let .readFailed(displayID, kind):
            return "Failed to read \(kind.title) over DDC for display \(displayID)."
        case let .writeFailed(displayID, kind):
            return "Failed to write \(kind.title) over DDC for display \(displayID)."
        }
    }
}
