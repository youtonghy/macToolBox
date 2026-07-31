import Foundation
import Yams

enum PaddleOCRConfigurationError: Error, Equatable {
    case malformedYAML
    case missingField(String)
}

struct PaddleOCRModelConfiguration: Equatable, Sendable {
    let detectionThreshold: Float
    let boxThreshold: Float
    let maximumCandidates: Int
    let unclipRatio: Float
    let recognitionImageShape: [Int]
    let characters: [String]

    init(detectionYAML: String, recognitionYAML: String) throws {
        guard let detection = try Yams.load(yaml: detectionYAML) as? [String: Any],
              let recognition = try Yams.load(yaml: recognitionYAML) as? [String: Any]
        else { throw PaddleOCRConfigurationError.malformedYAML }
        guard let postprocess = detection["PostProcess"] as? [String: Any] else {
            throw PaddleOCRConfigurationError.missingField("PostProcess")
        }
        guard let threshold = Self.float(postprocess["thresh"]),
              let boxThreshold = Self.float(postprocess["box_thresh"]),
              let maximumCandidates = Self.int(postprocess["max_candidates"]),
              let unclipRatio = Self.float(postprocess["unclip_ratio"])
        else { throw PaddleOCRConfigurationError.missingField("PostProcess parameters") }
        guard let recognitionPostprocess = recognition["PostProcess"] as? [String: Any],
              let characters = recognitionPostprocess["character_dict"] as? [String],
              !characters.isEmpty
        else { throw PaddleOCRConfigurationError.missingField("PostProcess.character_dict") }
        guard let preprocess = recognition["PreProcess"] as? [String: Any],
              let operations = preprocess["transform_ops"] as? [[String: Any]],
              let resize = operations.compactMap({ $0["RecResizeImg"] as? [String: Any] }).first,
              let rawShape = resize["image_shape"] as? [Any]
        else { throw PaddleOCRConfigurationError.missingField("RecResizeImg.image_shape") }
        let shape = rawShape.compactMap(Self.int)
        guard shape.count == 3, shape.allSatisfy({ $0 > 0 }) else {
            throw PaddleOCRConfigurationError.missingField("RecResizeImg.image_shape")
        }
        self.detectionThreshold = threshold
        self.boxThreshold = boxThreshold
        self.maximumCandidates = maximumCandidates
        self.unclipRatio = unclipRatio
        recognitionImageShape = shape
        self.characters = characters
    }

    init(modelDirectory: URL) throws {
        let detection = try String(
            contentsOf: modelDirectory.appendingPathComponent("det/inference.yml"),
            encoding: .utf8
        )
        let recognition = try String(
            contentsOf: modelDirectory.appendingPathComponent("rec/inference.yml"),
            encoding: .utf8
        )
        try self.init(detectionYAML: detection, recognitionYAML: recognition)
    }

    private static func float(_ value: Any?) -> Float? {
        if let value = value as? NSNumber { return value.floatValue }
        if let value = value as? String { return Float(value) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}
