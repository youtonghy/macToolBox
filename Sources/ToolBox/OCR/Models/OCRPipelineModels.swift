import Foundation

enum OCRPipelineID: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case ppOCRv6
    case ppStructureV3
    case paddleOCRVL

    var displayName: String {
        switch self {
        case .ppOCRv6: "PP-OCRv6"
        case .ppStructureV3: "PP-StructureV3"
        case .paddleOCRVL: "PaddleOCR-VL"
        }
    }

    var defaultVariantID: String {
        switch self {
        case .ppOCRv6: "tiny"
        case .ppStructureV3: "default"
        case .paddleOCRVL: "v1.6"
        }
    }

    var knownVariantIDs: Set<String> {
        switch self {
        case .ppOCRv6: Set(PPOCRv6Profile.allCases.map(\.rawValue))
        case .ppStructureV3: [defaultVariantID]
        case .paddleOCRVL: ["v1", "v1.5", "v1.6"]
        }
    }
}

struct OCRModelSelection: Codable, Equatable, Hashable, Sendable {
    var pipeline: OCRPipelineID
    var variantID: String

    init(
        pipeline: OCRPipelineID,
        variantID: String? = nil
    ) {
        self.pipeline = pipeline
        self.variantID = variantID ?? pipeline.defaultVariantID
    }

    var isKnownVariant: Bool {
        pipeline.knownVariantIDs.contains(variantID)
    }
}

enum PPOCRv6Profile: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case tiny
    case small
    case medium
}

enum OCRExecutionProvider: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case cpu
    case coreML

    // ONNX Runtime 1.24.3's Core ML provider can terminate the process while
    // being registered. Keep decoding the legacy value, but never execute it.
    var runtimeProvider: OCRExecutionProvider { .cpu }
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

    // The advanced pipelines use the bundled worker and are available on Apple
    // Silicon once the worker/model runtime is present in the app bundle.
    static let shipped = OCRRuntimeAvailability(gates: [
        Gate(
            pipeline: .ppOCRv6,
            architectures: [.arm64],
            deviceClasses: [.appleSiliconM1OrNewer]
        ),
        Gate(
            pipeline: .ppStructureV3,
            architectures: [.arm64],
            deviceClasses: [.appleSiliconM1OrNewer]
        ),
        Gate(
            pipeline: .paddleOCRVL,
            architectures: [.arm64],
            deviceClasses: [.appleSiliconM1OrNewer]
        ),
    ])
}
