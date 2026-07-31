import CoreGraphics
import Foundation

enum LocalPaddleOCREngineError: Error, Equatable {
    case invalidDetectionOutput([Int64])
    case invalidRecognitionShape([Int])
    case invalidImageSource
}

struct PaddleOCRRecognizedLine: Equatable, Sendable {
    let text: String
    let confidence: Double
    let bounds: CGRect
}

enum PaddleOCRRecognitionMerger {
    static func merge(
        _ candidates: [PaddleOCRRecognizedLine],
        imageSize: CGSize
    ) -> TextOCRDocument {
        var accepted: [PaddleOCRRecognizedLine] = []
        for candidate in candidates.sorted(by: { $0.confidence > $1.confidence }) {
            let duplicate = accepted.contains {
                $0.text == candidate.text && intersectionOverUnion($0.bounds, candidate.bounds) >= 0.35
            }
            if !duplicate { accepted.append(candidate) }
        }
        let width = max(1, imageSize.width)
        let height = max(1, imageSize.height)
        let lines = accepted.compactMap { line -> OCRTextLine? in
            let bounds = line.bounds.intersection(CGRect(origin: .zero, size: imageSize))
            guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
            let polygon = [
                CGPoint(x: bounds.minX / width, y: bounds.minY / height),
                CGPoint(x: bounds.maxX / width, y: bounds.minY / height),
                CGPoint(x: bounds.maxX / width, y: bounds.maxY / height),
                CGPoint(x: bounds.minX / width, y: bounds.maxY / height),
            ]
            return try? OCRTextLine(
                text: line.text,
                confidence: line.confidence,
                normalizedPolygon: polygon
            )
        }
        return TextOCRDocument(lines: lines)
    }

    private static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        let area = intersection.width * intersection.height
        let union = lhs.width * lhs.height + rhs.width * rhs.height - area
        return union > 0 ? area / union : 0
    }
}

actor LocalPaddleOCREngine {
    private let configuration: PaddleOCRModelConfiguration
    private let detectionSession: PaddleOCRInferenceSession
    private let recognitionSession: PaddleOCRInferenceSession
    private let tilePlanner: PaddleOCRTilePlanner
    private let minimumRecognitionConfidence: Float

    init(
        modelDirectory: URL,
        provider: OCRExecutionProvider,
        tilePlanner: PaddleOCRTilePlanner = try! PaddleOCRTilePlanner(),
        minimumRecognitionConfidence: Float = 0.35
    ) throws {
        configuration = try PaddleOCRModelConfiguration(modelDirectory: modelDirectory)
        detectionSession = try PaddleOCRInferenceSession(
            modelURL: modelDirectory.appendingPathComponent("det/inference.onnx"),
            provider: provider
        )
        recognitionSession = try PaddleOCRInferenceSession(
            modelURL: modelDirectory.appendingPathComponent("rec/inference.onnx"),
            provider: provider
        )
        self.tilePlanner = tilePlanner
        self.minimumRecognitionConfidence = minimumRecognitionConfidence
    }

    func recognize(source: ScreenshotImageSource) throws -> TextOCRDocument {
        let imageSize = source.pixelSize
        let tiles = tilePlanner.tiles(for: imageSize)
        guard !tiles.isEmpty else { throw LocalPaddleOCREngineError.invalidImageSource }
        var lines: [PaddleOCRRecognizedLine] = []
        for tile in tiles {
            try Task.checkCancellation()
            let image = try source.copyPixels(in: tile)
            lines.append(contentsOf: try recognize(tile: image, offset: tile.origin))
        }
        return PaddleOCRRecognitionMerger.merge(lines, imageSize: imageSize)
    }

    func recognize(image: CGImage) throws -> TextOCRDocument {
        try recognize(source: CGImageScreenshotSource(image: image))
    }

    private func recognize(tile image: CGImage, offset: CGPoint) throws -> [PaddleOCRRecognizedLine] {
        let input = try PaddleOCRImagePreprocessor.detectionTensor(image: image)
        let output = try detectionSession.run(input.tensor)
        guard output.shape.count >= 2,
              let rawWidth = output.shape.last,
              let rawHeight = output.shape.dropLast().last,
              rawWidth > 0,
              rawHeight > 0,
              rawWidth <= Int64(Int.max),
              rawHeight <= Int64(Int.max)
        else { throw LocalPaddleOCREngineError.invalidDetectionOutput(output.shape) }
        let processor = PaddleDBPostprocessor(
            threshold: configuration.detectionThreshold,
            boxThreshold: configuration.boxThreshold,
            maxCandidates: configuration.maximumCandidates,
            unclipRatio: configuration.unclipRatio
        )
        let detections = processor.process(
            probabilities: output.data,
            width: Int(rawWidth),
            height: Int(rawHeight),
            originalSize: input.originalSize
        )
        guard configuration.recognitionImageShape.count == 3,
              configuration.recognitionImageShape[0] == 3
        else {
            throw LocalPaddleOCREngineError.invalidRecognitionShape(
                configuration.recognitionImageShape
            )
        }
        let decoder = PaddleCTCDecoder(characters: configuration.characters)
        return try detections.compactMap { detection in
            try Task.checkCancellation()
            let cropRect = paddedCrop(detection.bounds, image: image)
            guard let crop = image.cropping(to: cropRect) else { return nil }
            let tensor = try PaddleOCRImagePreprocessor.recognitionTensor(
                image: crop,
                imageHeight: configuration.recognitionImageShape[1],
                defaultWidth: configuration.recognitionImageShape[2]
            )
            let recognitionOutput = try recognitionSession.run(tensor)
            let recognition = try decoder.decode(
                data: recognitionOutput.data,
                shape: recognitionOutput.shape
            )
            let text = recognition.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, recognition.confidence >= minimumRecognitionConfidence else {
                return nil
            }
            return PaddleOCRRecognizedLine(
                text: text,
                confidence: Double(recognition.confidence),
                bounds: cropRect.offsetBy(dx: offset.x, dy: offset.y)
            )
        }
    }

    private func paddedCrop(_ bounds: CGRect, image: CGImage) -> CGRect {
        let padding = max(2, min(bounds.width, bounds.height) * 0.04)
        return bounds.insetBy(dx: -padding, dy: -padding)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            .integral
    }
}
