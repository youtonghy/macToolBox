import Foundation
import OSLog

struct OCRSettings: Codable, Equatable, Sendable {
    var pipeline: OCRPipelineID
    var profile: PPOCRv6Profile
    var executionProvider: OCRExecutionProvider
    var localOnly: Bool

    static let `defaults` = OCRSettings(
        pipeline: .ppOCRv6,
        profile: .tiny,
        executionProvider: .cpu,
        localOnly: true
    )
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
            guard envelope.schemaVersion == 1 else {
                logger.error("Unknown OCR settings schema \(envelope.schemaVersion, privacy: .public)")
                return OCRSettingsLoadResult(
                    settings: .defaults,
                    issue: .unknownSchema(envelope.schemaVersion)
                )
            }
            let document = try decoder.decode(OCRSettingsDocumentV1.self, from: data)
            try validate(document.settings)
            return OCRSettingsLoadResult(settings: document.settings, issue: nil)
        } catch {
            logger.error("Corrupt OCR settings")
            return OCRSettingsLoadResult(settings: .defaults, issue: .corruptData)
        }
    }

    func save(_ settings: OCRSettings) throws {
        try validate(settings)
        defaults.set(
            try encoder.encode(OCRSettingsDocumentV1(schemaVersion: 1, settings: settings)),
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
    }
}

private struct OCRSettingsVersionEnvelope: Decodable {
    let schemaVersion: Int
}

private struct OCRSettingsDocumentV1: Codable {
    let schemaVersion: Int
    let settings: OCRSettings
}
