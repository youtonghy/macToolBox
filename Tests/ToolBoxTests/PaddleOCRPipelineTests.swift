import CoreGraphics
import XCTest
@testable import ToolBox

final class PaddleOCRPipelineTests: XCTestCase {
    func testParsesModelConfigurationWithStructuredYAML() throws {
        let detection = """
        PostProcess:
          thresh: 0.2
          box_thresh: 0.4
          max_candidates: 3000
          unclip_ratio: 1.4
        """
        let recognition = """
        PreProcess:
          transform_ops:
          - RecResizeImg:
              image_shape: [3, 48, 320]
        PostProcess:
          character_dict:
          - A
          - B
        """

        let config = try PaddleOCRModelConfiguration(
            detectionYAML: detection,
            recognitionYAML: recognition
        )

        XCTAssertEqual(config.detectionThreshold, 0.2, accuracy: 0.0001)
        XCTAssertEqual(config.boxThreshold, 0.4, accuracy: 0.0001)
        XCTAssertEqual(config.unclipRatio, 1.4, accuracy: 0.0001)
        XCTAssertEqual(config.recognitionImageShape, [3, 48, 320])
        XCTAssertEqual(config.characters, ["A", "B"])
    }

    func testCTCDecoderDropsBlanksAndConsecutiveDuplicates() throws {
        let decoder = PaddleCTCDecoder(characters: ["A", "B"])
        let output: [Float] = [
            0.9, 0.1, 0.0,
            0.1, 0.8, 0.1,
            0.1, 0.7, 0.2,
            0.8, 0.1, 0.1,
            0.1, 0.2, 0.7,
        ]

        let result = try decoder.decode(data: output, shape: [1, 5, 3])

        XCTAssertEqual(result.text, "AB")
        XCTAssertEqual(result.confidence, 0.75, accuracy: 0.0001)
    }

    func testDetectionPostprocessorMapsComponentsToOriginalCoordinates() {
        var probabilities = [Float](repeating: 0, count: 8 * 8)
        for y in 2...3 {
            for x in 1...5 { probabilities[y * 8 + x] = 0.9 }
        }
        let processor = PaddleDBPostprocessor(
            threshold: 0.2,
            boxThreshold: 0.4,
            maxCandidates: 10,
            unclipRatio: 1
        )

        let boxes = processor.process(
            probabilities: probabilities,
            width: 8,
            height: 8,
            originalSize: CGSize(width: 80, height: 40)
        )

        XCTAssertEqual(boxes.count, 1)
        XCTAssertEqual(boxes[0].bounds, CGRect(x: 10, y: 10, width: 50, height: 10))
        XCTAssertEqual(boxes[0].score, 0.9, accuracy: 0.0001)
    }

    func testRecognitionPreprocessorUsesBGRAndZeroPadding() throws {
        let image = try solidImage(red: 255, green: 128, blue: 0, width: 20, height: 10)

        let tensor = try PaddleOCRImagePreprocessor.recognitionTensor(
            image: image,
            imageHeight: 8,
            defaultWidth: 24,
            maximumWidth: 64
        )

        XCTAssertEqual(tensor.shape, [1, 3, 8, 24])
        XCTAssertEqual(tensor.data[0], -1, accuracy: 0.02)
        XCTAssertEqual(tensor.data[8 * 24], Float(128) / 127.5 - 1, accuracy: 0.02)
        XCTAssertEqual(tensor.data[2 * 8 * 24], 1, accuracy: 0.02)
        XCTAssertEqual(tensor.data[16], 0, accuracy: 0.0001)
    }

    func testTilePlannerCoversLongImageWithBoundedOverlappingTiles() throws {
        let planner = try PaddleOCRTilePlanner(maximumSide: 1_280, overlap: 96)

        let tiles = planner.tiles(for: CGSize(width: 900, height: 3_000))

        XCTAssertEqual(tiles, [
            CGRect(x: 0, y: 0, width: 900, height: 1_280),
            CGRect(x: 0, y: 1_184, width: 900, height: 1_280),
            CGRect(x: 0, y: 1_720, width: 900, height: 1_280),
        ])
        XCTAssertTrue(tiles.allSatisfy { $0.width <= 1_280 && $0.height <= 1_280 })
    }

    func testTilePlannerRejectsInvalidConfiguration() {
        XCTAssertThrowsError(try PaddleOCRTilePlanner(maximumSide: 100, overlap: 100)) {
            XCTAssertEqual($0 as? PaddleOCRTilePlannerError, .invalidConfiguration)
        }
    }

    func testRecognitionMergerKeepsHigherConfidenceDuplicate() throws {
        let first = PaddleOCRRecognizedLine(
            text: "ToolBox",
            confidence: 0.72,
            bounds: CGRect(x: 10, y: 100, width: 120, height: 30)
        )
        let duplicate = PaddleOCRRecognizedLine(
            text: "ToolBox",
            confidence: 0.94,
            bounds: CGRect(x: 12, y: 102, width: 118, height: 29)
        )
        let other = PaddleOCRRecognizedLine(
            text: "Screenshot",
            confidence: 0.81,
            bounds: CGRect(x: 10, y: 160, width: 150, height: 30)
        )

        let merged = PaddleOCRRecognitionMerger.merge(
            [first, duplicate, other],
            imageSize: CGSize(width: 500, height: 500)
        )

        XCTAssertEqual(merged.lines.count, 2)
        XCTAssertEqual(merged.lines.first?.text, "ToolBox")
        XCTAssertEqual(try XCTUnwrap(merged.lines.first).confidence, 0.94, accuracy: 0.0001)
    }

    private func solidImage(
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        width: Int,
        height: Int
    ) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = red
            pixels[index + 1] = green
            pixels[index + 2] = blue
            pixels[index + 3] = 255
        }
        let data = Data(pixels) as CFData
        let provider = CGDataProvider(data: data)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}
