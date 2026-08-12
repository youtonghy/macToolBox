import Foundation
import OSLog

struct OCRSettings: Codable, Equatable, Sendable {
    var selection: OCRModelSelection
    var executionProvider: OCRExecutionProvider
    var localOnly: Bool

    var pipeline: OCRPipelineID {
        get { selection.pipeline }
        set { selection = OCRModelSelection(pipeline: newValue) }
    }

    var profile: PPOCRv6Profile {
        get { PPOCRv6Profile(rawValue: selection.variantID) ?? .tiny }
        set {
            selection = OCRModelSelection(
                pipeline: .ppOCRv6,
                variantID: newValue.rawValue
            )
        }
    }

    var normalizedForRuntime: OCRSettings {
        var normalized = self
        normalized.executionProvider = executionProvider.runtimeProvider
        return normalized
    }

    static let `defaults` = OCRSettings(
        selection: OCRModelSelection(pipeline: .ppOCRv6, variantID: "tiny"),
        executionProvider: .cpu,
        localOnly: true
    )

    init(
        selection: OCRModelSelection,
        executionProvider: OCRExecutionProvider,
        localOnly: Bool
    ) {
        self.selection = selection
        self.executionProvider = executionProvider
        self.localOnly = localOnly
    }

    private enum CodingKeys: String, CodingKey {
        case selection
        case pipeline
        case profile
        case executionProvider
        case localOnly
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let selection = try container.decodeIfPresent(
            OCRModelSelection.self,
            forKey: .selection
        ) {
            self.selection = selection
        } else {
            let pipeline = try container.decode(OCRPipelineID.self, forKey: .pipeline)
            let profile = try container.decode(PPOCRv6Profile.self, forKey: .profile)
            self.selection = OCRModelSelection(
                pipeline: pipeline,
                variantID: profile.rawValue
            )
        }
        executionProvider = try container.decode(
            OCRExecutionProvider.self,
            forKey: .executionProvider
        )
        localOnly = try container.decode(Bool.self, forKey: .localOnly)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(selection, forKey: .selection)
        try container.encode(executionProvider, forKey: .executionProvider)
        try container.encode(localOnly, forKey: .localOnly)
    }
}

struct OCRSettingsLoadResult: Equatable, Sendable {
    let settings: OCRSettings
    let issue: OCRSettingsStoreIssue?
}

enum OCRSettingsStoreIssue: Equatable, Sendable {
    case corruptData
    case unknownSchema(Int)
}

enum OCRSettingsError: Error, Equatable {
    case cloudFallbackForbidden
    case unavailablePipeline
    case unavailableVariant
}

struct OCRSettingsStore {
    static let defaultKey = "screenshot.ocr.settings.v1"

    private let defaults: UserDefaults
    private let key: String
    private let availability: OCRRuntimeAvailability
    private let architecture: OCRRuntimeArchitecture
    private let deviceClass: OCRDeviceClass
    private let logger = Logger(subsystem: "ToolBox", category: "OCRSettingsStore")
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        key: String = OCRSettingsStore.defaultKey,
        availability: OCRRuntimeAvailability = .shipped,
        architecture: OCRRuntimeArchitecture = .arm64,
        deviceClass: OCRDeviceClass = .appleSiliconM1OrNewer
    ) {
        self.defaults = defaults
        self.key = key
        self.availability = availability
        self.architecture = architecture
        self.deviceClass = deviceClass
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    func load() -> OCRSettingsLoadResult {
        guard let data = defaults.data(forKey: key) else {
            return OCRSettingsLoadResult(settings: .defaults, issue: nil)
        }
        do {
            let envelope = try decoder.decode(OCRSettingsVersionEnvelope.self, from: data)
            guard envelope.schemaVersion == 1 || envelope.schemaVersion == 2 else {
                logger.error("Unknown OCR settings schema \(envelope.schemaVersion, privacy: .public)")
                CorruptDefaultsBackup.backup(defaults: defaults, key: key)
                return OCRSettingsLoadResult(
                    settings: .defaults,
                    issue: .unknownSchema(envelope.schemaVersion)
                )
            }
            let document = try decoder.decode(OCRSettingsDocumentV1.self, from: data)
            let settings = document.settings.normalizedForRuntime
            try validate(settings)
            return OCRSettingsLoadResult(settings: settings, issue: nil)
        } catch {
            logger.error("Corrupt OCR settings")
            CorruptDefaultsBackup.backup(defaults: defaults, key: key)
            return OCRSettingsLoadResult(settings: .defaults, issue: .corruptData)
        }
    }

    func save(_ settings: OCRSettings) throws {
        let settings = settings.normalizedForRuntime
        try validate(settings)
        defaults.set(
            try encoder.encode(OCRSettingsDocumentV1(schemaVersion: 2, settings: settings)),
            forKey: key
        )
    }

    private func validate(_ settings: OCRSettings) throws {
        guard settings.localOnly else { throw OCRSettingsError.cloudFallbackForbidden }
        let available = availability.availablePipelines(
            architecture: architecture,
            deviceClass: deviceClass
        )
        guard available.contains(settings.pipeline) else { throw OCRSettingsError.unavailablePipeline }
        guard settings.selection.isKnownVariant else {
            throw OCRSettingsError.unavailableVariant
        }
    }
}

private struct OCRSettingsVersionEnvelope: Decodable {
    let schemaVersion: Int
}

private struct OCRSettingsDocumentV1: Codable {
    let schemaVersion: Int
    let settings: OCRSettings
}
