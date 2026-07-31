import Foundation

enum OCRPipelineID: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case ppOCRv6
    case ppStructureV3
    case paddleOCRVL
}

enum PPOCRv6Profile: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case tiny
    case small
    case medium
}

enum OCRExecutionProvider: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case cpu
    case coreML
}

enum OCRRuntimeArchitecture: String, Codable, Equatable, Sendable {
    case arm64
    case x86_64
}

enum OCRDeviceClass: String, Codable, Equatable, Sendable {
    case appleSiliconM1OrNewer
    case intel
}

struct OCRRuntimeAvailability: Equatable, Sendable {
    struct Gate: Equatable, Sendable {
        let pipeline: OCRPipelineID
        let architectures: Set<OCRRuntimeArchitecture>
        let deviceClasses: Set<OCRDeviceClass>
    }

    let gates: [Gate]

    func availablePipelines(
        architecture: OCRRuntimeArchitecture,
        deviceClass: OCRDeviceClass
    ) -> [OCRPipelineID] {
        gates.compactMap { gate in
            guard gate.architectures.contains(architecture),
                  gate.deviceClasses.contains(deviceClass)
            else { return nil }
            return gate.pipeline
        }
    }

    // Advanced workers stay absent until their signing, notarization and device gates pass.
    static let shipped = OCRRuntimeAvailability(gates: [
        Gate(
            pipeline: .ppOCRv6,
            architectures: [.arm64],
            deviceClasses: [.appleSiliconM1OrNewer]
        ),
    ])
}
