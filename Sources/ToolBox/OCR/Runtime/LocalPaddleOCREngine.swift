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
    let polygon: [CGPoint]

    init(text: String, confidence: Double, bounds: CGRect, polygon: [CGPoint]? = nil) {
        self.text = text
        self.confidence = confidence
        self.bounds = bounds
        self.polygon = polygon ?? [
            CGPoint(x: bounds.minX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.maxY),
            CGPoint(x: bounds.minX, y: bounds.maxY),
        ]
    }
}

enum PaddleOCRRecognitionMerger {
    static func merge(
        _ candidates: [PaddleOCRRecognizedLine],
        imageSize: CGSize
    ) -> TextOCRDocument {
        var accepted: [PaddleOCRRecognizedLine] = []
        for candidate in candidates.sorted(by: {
            if $0.text.count != $1.text.count { return $0.text.count > $1.text.count }
            return $0.confidence > $1.confidence
        }) {
            let duplicate = accepted.contains { isDuplicate($0, candidate) }
            if !duplicate { accepted.append(candidate) }
        }
        let width = max(1, imageSize.width)
        let height = max(1, imageSize.height)
        let lines = accepted.compactMap { line -> OCRTextLine? in
            let bounds = line.bounds.intersection(CGRect(origin: .zero, size: imageSize))
            guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
            let polygon = line.polygon.map {
                CGPoint(
                    x: min(1, max(0, $0.x / width)),
                    y: min(1, max(0, $0.y / height))
                )
            }
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

    private static func isDuplicate(
        _ accepted: PaddleOCRRecognizedLine,
        _ candidate: PaddleOCRRecognizedLine
    ) -> Bool {
        let iou = intersectionOverUnion(accepted.bounds, candidate.bounds)
        if accepted.text == candidate.text { return iou >= 0.35 }
        guard accepted.text.contains(candidate.text) || candidate.text.contains(accepted.text) else {
            return false
        }
        let intersection = accepted.bounds.intersection(candidate.bounds)
        guard !intersection.isNull else { return false }
        let smallerArea = min(
            accepted.bounds.width * accepted.bounds.height,
            candidate.bounds.width * candidate.bounds.height
        )
        let covered = smallerArea > 0 ? intersection.width * intersection.height / smallerArea : 0
        let rowOverlap = intersection.height / max(1, CGFloat(min(accepted.bounds.height, candidate.bounds.height)))
        return covered >= 0.55 && rowOverlap >= 0.7
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
        guard !detections.isEmpty else { return [] }
        guard configuration.recognitionImageShape.count == 3,
              configuration.recognitionImageShape[0] == 3
        else {
            throw LocalPaddleOCREngineError.invalidRecognitionShape(
                configuration.recognitionImageShape
            )
        }
        let decoder = PaddleCTCDecoder(characters: configuration.characters)
        let rasterizedImage = try PaddleOCRImagePreprocessor.rasterizedImage(image: image)
        return try detections.compactMap { detection in
            try Task.checkCancellation()
            let crop = try PaddleOCRImagePreprocessor.perspectiveCrop(
                source: rasterizedImage,
                quadrilateral: detection.polygon
            )
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
                bounds: detection.bounds.offsetBy(dx: offset.x, dy: offset.y),
                polygon: detection.polygon.map {
                    CGPoint(x: $0.x + offset.x, y: $0.y + offset.y)
                }
            )
        }
    }
}
