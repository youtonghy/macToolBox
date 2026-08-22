import Foundation

public enum ToolBoxControlProtocolVersion {
    public static let current = 1
}

@objc public protocol ToolBoxControlXPCProtocol {
    func execute(_ requestData: Data, withReply reply: @escaping (Data) -> Void)
}

public enum ToolBoxControlCommand: String, Codable, CaseIterable, Sendable {
    case status
    case displayList = "display.list"
    case displayGet = "display.get"
    case displaySet = "display.set"
    case focusStatus = "focus.status"
    case focusSet = "focus.set"
    case audioApps = "audio.apps"
    case audioDevices = "audio.devices"
    case audioGet = "audio.get"
    case audioSet = "audio.set"
    case awake
    case launchAtLogin = "launch-at-login"
}

public struct ToolBoxControlRequestEnvelope: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let request: ToolBoxControlRequest

    public init(
        requestID: String = UUID().uuidString.lowercased(),
        request: ToolBoxControlRequest,
        protocolVersion: Int = ToolBoxControlProtocolVersion.current
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.request = request
    }
}

public enum ToolBoxControlRequest: Equatable, Sendable {
    case status
    case displayList
    case displayGet(ToolBoxDisplayTargetDTO)
    case displaySet(ToolBoxDisplaySetRequestDTO)
    case focusStatus
    case focusSet(ToolBoxFocusSetRequestDTO)
    case audioApps
    case audioDevices
    case audioGet(ToolBoxAudioGetRequestDTO)
    case audioSet(ToolBoxAudioSetRequestDTO)
    case awake(ToolBoxToggleRequestDTO)
    case launchAtLogin(ToolBoxToggleRequestDTO)
}

extension ToolBoxControlRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case command
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let command = try container.decode(ToolBoxControlCommand.self, forKey: .command)
        switch command {
        case .status:
            self = .status
        case .displayList:
            self = .displayList
        case .displayGet:
            self = .displayGet(try container.decode(ToolBoxDisplayTargetDTO.self, forKey: .payload))
        case .displaySet:
            self = .displaySet(try container.decode(ToolBoxDisplaySetRequestDTO.self, forKey: .payload))
        case .focusStatus:
            self = .focusStatus
        case .focusSet:
            self = .focusSet(try container.decode(ToolBoxFocusSetRequestDTO.self, forKey: .payload))
        case .audioApps:
            self = .audioApps
        case .audioDevices:
            self = .audioDevices
        case .audioGet:
            self = .audioGet(try container.decode(ToolBoxAudioGetRequestDTO.self, forKey: .payload))
        case .audioSet:
            self = .audioSet(try container.decode(ToolBoxAudioSetRequestDTO.self, forKey: .payload))
        case .awake:
            self = .awake(try container.decode(ToolBoxToggleRequestDTO.self, forKey: .payload))
        case .launchAtLogin:
            self = .launchAtLogin(try container.decode(ToolBoxToggleRequestDTO.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status:
            try container.encode(ToolBoxControlCommand.status, forKey: .command)
        case .displayList:
            try container.encode(ToolBoxControlCommand.displayList, forKey: .command)
        case let .displayGet(payload):
            try container.encode(ToolBoxControlCommand.displayGet, forKey: .command)
            try container.encode(payload, forKey: .payload)
        case let .displaySet(payload):
            try container.encode(ToolBoxControlCommand.displaySet, forKey: .command)
            try container.encode(payload, forKey: .payload)
        case .focusStatus:
            try container.encode(ToolBoxControlCommand.focusStatus, forKey: .command)
        case let .focusSet(payload):
            try container.encode(ToolBoxControlCommand.focusSet, forKey: .command)
            try container.encode(payload, forKey: .payload)
        case .audioApps:
            try container.encode(ToolBoxControlCommand.audioApps, forKey: .command)
        case .audioDevices:
            try container.encode(ToolBoxControlCommand.audioDevices, forKey: .command)
        case let .audioGet(payload):
            try container.encode(ToolBoxControlCommand.audioGet, forKey: .command)
            try container.encode(payload, forKey: .payload)
        case let .audioSet(payload):
            try container.encode(ToolBoxControlCommand.audioSet, forKey: .command)
            try container.encode(payload, forKey: .payload)
        case let .awake(payload):
            try container.encode(ToolBoxControlCommand.awake, forKey: .command)
            try container.encode(payload, forKey: .payload)
        case let .launchAtLogin(payload):
            try container.encode(ToolBoxControlCommand.launchAtLogin, forKey: .command)
            try container.encode(payload, forKey: .payload)
        }
    }
}

public struct ToolBoxControlResponseEnvelope: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let result: ToolBoxControlResult?
    public let error: ToolBoxControlErrorDTO?
    public let warnings: [ToolBoxControlWarningDTO]

    public init(
        protocolVersion: Int = ToolBoxControlProtocolVersion.current,
        requestID: String,
        result: ToolBoxControlResult?,
        error: ToolBoxControlErrorDTO?,
        warnings: [ToolBoxControlWarningDTO] = []
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.result = result
        self.error = error
        self.warnings = warnings
    }

    public static func success(
        requestID: String,
        result: ToolBoxControlResult,
        warnings: [ToolBoxControlWarningDTO] = []
    ) -> ToolBoxControlResponseEnvelope {
        ToolBoxControlResponseEnvelope(
            requestID: requestID,
            result: result,
            error: nil,
            warnings: warnings
        )
    }

    public static func failure(
        requestID: String,
        error: ToolBoxControlErrorDTO,
        warnings: [ToolBoxControlWarningDTO] = []
    ) -> ToolBoxControlResponseEnvelope {
        ToolBoxControlResponseEnvelope(
            requestID: requestID,
            result: nil,
            error: error,
            warnings: warnings
        )
    }
}

public enum ToolBoxControlResult: Equatable, Sendable {
    case status(ToolBoxStatusDTO)
    case displayList(ToolBoxDisplayListDTO)
    case display(ToolBoxDisplayDTO)
    case focus(ToolBoxFocusDTO)
    case audioApps(ToolBoxAudioAppListDTO)
    case audioDevices(ToolBoxAudioDeviceListDTO)
    case audioRule(ToolBoxAudioRuleDTO)
    case awake(ToolBoxToggleStateDTO)
    case launchAtLogin(ToolBoxToggleStateDTO)
}

extension ToolBoxControlResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    private enum Kind: String, Codable {
        case status
        case displayList = "display.list"
        case display
        case focus
        case audioApps = "audio.apps"
        case audioDevices = "audio.devices"
        case audioRule = "audio.rule"
        case awake
        case launchAtLogin = "launch-at-login"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .status:
            self = .status(try container.decode(ToolBoxStatusDTO.self, forKey: .payload))
        case .displayList:
            self = .displayList(try container.decode(ToolBoxDisplayListDTO.self, forKey: .payload))
        case .display:
            self = .display(try container.decode(ToolBoxDisplayDTO.self, forKey: .payload))
        case .focus:
            self = .focus(try container.decode(ToolBoxFocusDTO.self, forKey: .payload))
        case .audioApps:
            self = .audioApps(try container.decode(ToolBoxAudioAppListDTO.self, forKey: .payload))
        case .audioDevices:
            self = .audioDevices(try container.decode(ToolBoxAudioDeviceListDTO.self, forKey: .payload))
        case .audioRule:
            self = .audioRule(try container.decode(ToolBoxAudioRuleDTO.self, forKey: .payload))
        case .awake:
            self = .awake(try container.decode(ToolBoxToggleStateDTO.self, forKey: .payload))
        case .launchAtLogin:
            self = .launchAtLogin(try container.decode(ToolBoxToggleStateDTO.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .status(payload):
            try container.encode(Kind.status, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case let .displayList(payload):
            try container.encode(Kind.displayList, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case let .display(payload):
            try container.encode(Kind.display, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case let .focus(payload):
            try container.encode(Kind.focus, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case let .audioApps(payload):
            try container.encode(Kind.audioApps, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case let .audioDevices(payload):
            try container.encode(Kind.audioDevices, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case let .audioRule(payload):
            try container.encode(Kind.audioRule, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case let .awake(payload):
            try container.encode(Kind.awake, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case let .launchAtLogin(payload):
            try container.encode(Kind.launchAtLogin, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        }
    }
}
