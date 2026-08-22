import Foundation

public struct ToolBoxDisplayTargetDTO: Codable, Equatable, Sendable {
    public let displayID: UInt32?
    public let serial: String?

    public init(displayID: UInt32? = nil, serial: String? = nil) {
        self.displayID = displayID
        self.serial = serial
    }
}

public struct ToolBoxDisplaySetRequestDTO: Codable, Equatable, Sendable {
    public let target: ToolBoxDisplayTargetDTO
    public let change: ToolBoxDisplayChangeDTO

    public init(target: ToolBoxDisplayTargetDTO, change: ToolBoxDisplayChangeDTO) {
        self.target = target
        self.change = change
    }
}

public enum ToolBoxDisplayChangeDTO: Equatable, Sendable {
    case brightness(Int)
    case contrast(Int)
    case volume(Int)
    case mute(Bool)
    case preset(String)
}

extension ToolBoxDisplayChangeDTO: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case brightness
        case contrast
        case volume
        case mute
        case preset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .brightness:
            self = .brightness(try container.decode(Int.self, forKey: .value))
        case .contrast:
            self = .contrast(try container.decode(Int.self, forKey: .value))
        case .volume:
            self = .volume(try container.decode(Int.self, forKey: .value))
        case .mute:
            self = .mute(try container.decode(Bool.self, forKey: .value))
        case .preset:
            self = .preset(try container.decode(String.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .brightness(value):
            try container.encode(Kind.brightness, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .contrast(value):
            try container.encode(Kind.contrast, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .volume(value):
            try container.encode(Kind.volume, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .mute(value):
            try container.encode(Kind.mute, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .preset(value):
            try container.encode(Kind.preset, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

public struct ToolBoxFocusSetRequestDTO: Codable, Equatable, Sendable {
    public let isEnabled: Bool?
    public let opacityPercent: Int?

    public init(isEnabled: Bool? = nil, opacityPercent: Int? = nil) {
        self.isEnabled = isEnabled
        self.opacityPercent = opacityPercent
    }
}

public struct ToolBoxAudioGetRequestDTO: Codable, Equatable, Sendable {
    public let bundleID: String

    public init(bundleID: String) {
        self.bundleID = bundleID
    }

    private enum CodingKeys: String, CodingKey {
        case bundleID = "bundleId"
    }
}

public struct ToolBoxAudioSetRequestDTO: Codable, Equatable, Sendable {
    public let bundleID: String
    public let change: ToolBoxAudioChangeDTO

    public init(bundleID: String, change: ToolBoxAudioChangeDTO) {
        self.bundleID = bundleID
        self.change = change
    }

    private enum CodingKeys: String, CodingKey {
        case bundleID = "bundleId"
        case change
    }
}

public enum ToolBoxAudioChangeDTO: Equatable, Sendable {
    case volume(Int)
    case outputDevice(ToolBoxAudioOutputSelectionDTO)
}

extension ToolBoxAudioChangeDTO: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case volume
        case outputDevice = "output-device"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .volume:
            self = .volume(try container.decode(Int.self, forKey: .value))
        case .outputDevice:
            self = .outputDevice(try container.decode(ToolBoxAudioOutputSelectionDTO.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .volume(value):
            try container.encode(Kind.volume, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .outputDevice(value):
            try container.encode(Kind.outputDevice, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

public enum ToolBoxAudioOutputSelectionDTO: Equatable, Sendable {
    case systemDefault
    case device(uid: String)
}

extension ToolBoxAudioOutputSelectionDTO: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case uid
    }

    private enum Kind: String, Codable {
        case systemDefault = "system-default"
        case device
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .systemDefault:
            self = .systemDefault
        case .device:
            self = .device(uid: try container.decode(String.self, forKey: .uid))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .systemDefault:
            try container.encode(Kind.systemDefault, forKey: .kind)
        case let .device(uid):
            try container.encode(Kind.device, forKey: .kind)
            try container.encode(uid, forKey: .uid)
        }
    }
}

public enum ToolBoxToggleAction: String, Codable, Sendable {
    case status
    case on
    case off
}

public struct ToolBoxToggleRequestDTO: Codable, Equatable, Sendable {
    public let action: ToolBoxToggleAction

    public init(action: ToolBoxToggleAction) {
        self.action = action
    }
}

public struct ToolBoxStatusDTO: Codable, Equatable, Sendable {
    public let appVersion: String
    public let processIdentifier: Int32
    public let capabilities: [ToolBoxCapabilityDTO]
    public let displayCount: Int
    public let audioAppCount: Int
    public let focusEnabled: Bool
    public let awakeEnabled: Bool
    public let launchAtLoginEnabled: Bool

    public init(
        appVersion: String,
        processIdentifier: Int32,
        capabilities: [ToolBoxCapabilityDTO],
        displayCount: Int,
        audioAppCount: Int,
        focusEnabled: Bool,
        awakeEnabled: Bool,
        launchAtLoginEnabled: Bool
    ) {
        self.appVersion = appVersion
        self.processIdentifier = processIdentifier
        self.capabilities = capabilities
        self.displayCount = displayCount
        self.audioAppCount = audioAppCount
        self.focusEnabled = focusEnabled
        self.awakeEnabled = awakeEnabled
        self.launchAtLoginEnabled = launchAtLoginEnabled
    }
}

public struct ToolBoxCapabilityDTO: Codable, Equatable, Sendable {
    public let name: String
    public let isAvailable: Bool
    public let reason: String?

    public init(name: String, isAvailable: Bool, reason: String? = nil) {
        self.name = name
        self.isAvailable = isAvailable
        self.reason = reason
    }
}

public enum ToolBoxDisplayControlKind: String, Codable, Sendable {
    case brightness
    case contrast
    case volume
    case mute
    case preset
}

public struct ToolBoxDisplayControlDTO: Codable, Equatable, Sendable {
    public let kind: ToolBoxDisplayControlKind
    public let minimum: Int?
    public let maximum: Int?
    public let currentValue: String?
    public let isReadable: Bool
    public let isWritable: Bool

    public init(
        kind: ToolBoxDisplayControlKind,
        minimum: Int? = nil,
        maximum: Int? = nil,
        currentValue: String? = nil,
        isReadable: Bool,
        isWritable: Bool
    ) {
        self.kind = kind
        self.minimum = minimum
        self.maximum = maximum
        self.currentValue = currentValue
        self.isReadable = isReadable
        self.isWritable = isWritable
    }
}

public struct ToolBoxDisplayDTO: Codable, Equatable, Sendable {
    public let displayID: UInt32
    public let serial: String?
    public let name: String
    public let isBuiltIn: Bool
    public let controls: [ToolBoxDisplayControlDTO]

    public init(
        displayID: UInt32,
        serial: String? = nil,
        name: String,
        isBuiltIn: Bool,
        controls: [ToolBoxDisplayControlDTO]
    ) {
        self.displayID = displayID
        self.serial = serial
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.controls = controls
    }
}

public struct ToolBoxDisplayListDTO: Codable, Equatable, Sendable {
    public let displays: [ToolBoxDisplayDTO]

    public init(displays: [ToolBoxDisplayDTO]) {
        self.displays = displays
    }
}

public struct ToolBoxFocusDTO: Codable, Equatable, Sendable {
    public let isEnabled: Bool
    public let opacityPercent: Int
    public let permissionGranted: Bool

    public init(isEnabled: Bool, opacityPercent: Int, permissionGranted: Bool) {
        self.isEnabled = isEnabled
        self.opacityPercent = opacityPercent
        self.permissionGranted = permissionGranted
    }
}

public enum ToolBoxAudioRuleState: String, Codable, Sendable {
    case configured
    case pending
    case active
    case failed
}

public struct ToolBoxAudioAppDTO: Codable, Equatable, Sendable {
    public let bundleID: String
    public let name: String
    public let processIdentifier: Int32?
    public let isRunning: Bool
    public let isProducingOutput: Bool
    public let hasSavedRule: Bool

    public init(
        bundleID: String,
        name: String,
        processIdentifier: Int32? = nil,
        isRunning: Bool,
        isProducingOutput: Bool,
        hasSavedRule: Bool
    ) {
        self.bundleID = bundleID
        self.name = name
        self.processIdentifier = processIdentifier
        self.isRunning = isRunning
        self.isProducingOutput = isProducingOutput
        self.hasSavedRule = hasSavedRule
    }

    private enum CodingKeys: String, CodingKey {
        case bundleID = "bundleId"
        case name, processIdentifier, isRunning, isProducingOutput, hasSavedRule
    }
}

public struct ToolBoxAudioAppListDTO: Codable, Equatable, Sendable {
    public let apps: [ToolBoxAudioAppDTO]

    public init(apps: [ToolBoxAudioAppDTO]) {
        self.apps = apps
    }
}

public struct ToolBoxAudioDeviceDTO: Codable, Equatable, Sendable {
    public let uid: String
    public let name: String
    public let isAvailable: Bool
    public let isRoutable: Bool
    public let sampleRate: Double?
    public let issue: String?

    public init(
        uid: String,
        name: String,
        isAvailable: Bool,
        isRoutable: Bool,
        sampleRate: Double? = nil,
        issue: String? = nil
    ) {
        self.uid = uid
        self.name = name
        self.isAvailable = isAvailable
        self.isRoutable = isRoutable
        self.sampleRate = sampleRate
        self.issue = issue
    }
}

public struct ToolBoxAudioDeviceListDTO: Codable, Equatable, Sendable {
    public let devices: [ToolBoxAudioDeviceDTO]

    public init(devices: [ToolBoxAudioDeviceDTO]) {
        self.devices = devices
    }
}

public struct ToolBoxAudioRuleDTO: Codable, Equatable, Sendable {
    public let bundleID: String
    public let volumePercent: Int
    public let outputDeviceUID: String?
    public let state: ToolBoxAudioRuleState
    public let issue: String?

    public init(
        bundleID: String,
        volumePercent: Int,
        outputDeviceUID: String? = nil,
        state: ToolBoxAudioRuleState,
        issue: String? = nil
    ) {
        self.bundleID = bundleID
        self.volumePercent = volumePercent
        self.outputDeviceUID = outputDeviceUID
        self.state = state
        self.issue = issue
    }

    private enum CodingKeys: String, CodingKey {
        case bundleID = "bundleId"
        case volumePercent
        case outputDeviceUID = "outputDeviceUid"
        case state, issue
    }
}

public struct ToolBoxToggleStateDTO: Codable, Equatable, Sendable {
    public let isEnabled: Bool

    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }
}

public enum ToolBoxControlErrorCode: String, Codable, Sendable {
    case invalidRequest = "invalid-request"
    case unsupportedProtocolVersion = "unsupported-protocol-version"
    case permissionDenied = "permission-denied"
    case unavailable
    case timedOut = "timed-out"
    case notFound = "not-found"
    case ambiguousTarget = "ambiguous-target"
    case unsupported
    case conflict
    case operationFailed = "operation-failed"
    case internalError = "internal-error"
}

public struct ToolBoxControlErrorDTO: Codable, Equatable, Sendable {
    public let code: ToolBoxControlErrorCode
    public let message: String
    public let details: [String: String]
    public let isRecoverable: Bool

    public init(
        code: ToolBoxControlErrorCode,
        message: String,
        details: [String: String] = [:],
        isRecoverable: Bool = false
    ) {
        self.code = code
        self.message = message
        self.details = details
        self.isRecoverable = isRecoverable
    }
}

public enum ToolBoxControlWarningCode: String, Codable, Sendable {
    case writeUnverified = "write-unverified"
    case configuredNotActive = "configured-not-active"
    case degraded
    case partialResult = "partial-result"
}

public struct ToolBoxControlWarningDTO: Codable, Equatable, Sendable {
    public let code: ToolBoxControlWarningCode
    public let message: String
    public let details: [String: String]

    public init(
        code: ToolBoxControlWarningCode,
        message: String,
        details: [String: String] = [:]
    ) {
        self.code = code
        self.message = message
        self.details = details
    }
}
