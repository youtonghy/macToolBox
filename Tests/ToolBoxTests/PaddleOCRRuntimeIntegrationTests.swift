import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import ToolBox

final class PaddleOCRRuntimeIntegrationTests: XCTestCase {
    @MainActor
    func testEditorModelPassesDiagnosticImageThroughProductionOCRService() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let imagePath = environment["TOOLBOX_OCR_DIAGNOSTIC_IMAGE"]
        else { throw XCTSkip("Set the OCR diagnostic image path") }
        let imageURL = URL(fileURLWithPath: imagePath)
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else { return XCTFail("Unable to decode the OCR diagnostic image") }
        let document = ScreenshotDocument(baseImage: CGImageScreenshotSource(image: image))
        let preview = try ScreenshotEditorPreviewBuilder().makeBasePreview(document: document)
        let model = try ScreenshotEditorModel(document: document, preview: preview)

        model.requestOCR()
        for _ in 0..<600 where model.isRecognizing {
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertFalse(model.isRecognizing, "Production OCR service timed out")
        XCTAssertNil(model.errorMessage)
        let result = try XCTUnwrap(model.ocrDocument)
        print("[OCR diagnostic/editor-model]\n\(result.plainText)")
        if let expectedText = environment["TOOLBOX_OCR_DIAGNOSTIC_EXPECTED_TEXT"] {
            XCTAssertTrue(
                result.plainText.contains(expectedText),
                "Editor OCR did not contain expected text: \(expectedText)"
            )
        }
    }

    func testDiagnosticImageReportsDirectAndScrollSourceOCR() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["TOOLBOX_OCR_TEST_MODEL_DIR"],
              let imagePath = environment["TOOLBOX_OCR_DIAGNOSTIC_IMAGE"]
        else { throw XCTSkip("Set the local PaddleOCR model and diagnostic image paths") }
        let imageURL = URL(fileURLWithPath: imagePath)
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else { return XCTFail("Unable to decode the OCR diagnostic image") }
        let engine = try LocalPaddleOCREngine(
            modelDirectory: URL(fileURLWithPath: modelPath, isDirectory: true),
            provider: .cpu
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-diagnostic-source-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ScrollCaptureStripStore(initialImage: image, rootDirectory: root)

        let direct = try await engine.recognize(image: image)
        let fromScrollSource = try await engine.recognize(source: store.makeImageSource())

        print("[OCR diagnostic/direct]\n\(direct.plainText)")
        print("[OCR diagnostic/scroll]\n\(fromScrollSource.plainText)")
        if let expectedText = environment["TOOLBOX_OCR_DIAGNOSTIC_EXPECTED_TEXT"] {
            XCTAssertTrue(
                direct.plainText.contains(expectedText),
                "Direct OCR did not contain expected text: \(expectedText)"
            )
            XCTAssertTrue(
                fromScrollSource.plainText.contains(expectedText),
                "Scroll-source OCR did not contain expected text: \(expectedText)"
            )
        }
    }

    func testDiagnosticImageReportsStaticCaptureComposerOCR() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["TOOLBOX_OCR_TEST_MODEL_DIR"],
              let imagePath = environment["TOOLBOX_OCR_DIAGNOSTIC_IMAGE"]
        else { throw XCTSkip("Set the local PaddleOCR model and diagnostic image paths") }
        let imageURL = URL(fileURLWithPath: imagePath)
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else { return XCTFail("Unable to decode the OCR diagnostic image") }
        let imageSize = CGSize(width: image.width, height: image.height)
        let geometry = DisplayCaptureGeometry(
            displayID: 1,
            globalFramePoints: CGRect(origin: .zero, size: imageSize),
            pixelSize: imageSize
        )
        let composed = try ScreenshotImageComposer.compose(
            selection: geometry.globalFramePoints,
            frames: [DisplayCaptureFrame(geometry: geometry, image: image)]
        )
        let engine = try LocalPaddleOCREngine(
            modelDirectory: URL(fileURLWithPath: modelPath, isDirectory: true),
            provider: .cpu
        )

        let direct = try await engine.recognize(image: image)
        let fromStaticComposer = try await engine.recognize(image: composed)

        print("[OCR diagnostic/direct]\n\(direct.plainText)")
        print("[OCR diagnostic/static-composer]\n\(fromStaticComposer.plainText)")
        if let expectedText = environment["TOOLBOX_OCR_DIAGNOSTIC_EXPECTED_TEXT"] {
            XCTAssertTrue(
                direct.plainText.contains(expectedText),
                "Direct OCR did not contain expected text: \(expectedText)"
            )
            XCTAssertTrue(
                fromStaticComposer.plainText.contains(expectedText),
                "Static-composer OCR did not contain expected text: \(expectedText)"
            )
        }
    }

    func testOfficialTinyModelRecognizesOfficialSample() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["TOOLBOX_OCR_TEST_MODEL_DIR"],
              let imagePath = environment["TOOLBOX_OCR_TEST_IMAGE"]
        else { throw XCTSkip("Set the local PaddleOCR model and sample image paths") }
        let imageURL = URL(fileURLWithPath: imagePath)
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return XCTFail("Unable to decode the OCR sample image") }
        let engine = try LocalPaddleOCREngine(
            modelDirectory: URL(fileURLWithPath: modelPath, isDirectory: true),
            provider: .cpu
        )

        let document = try await engine.recognize(image: image)
        let text = document.plainText.uppercased()

        XCTAssertFalse(document.lines.isEmpty)
        XCTAssertTrue(
            text.contains("BOARDING") || text.contains("FUZHOU") || text.contains("TAIYUAN"),
            "Unexpected OCR output: \(document.plainText)"
        )
    }

    func testOfficialTinyModelProducesEquivalentTextForScrollCaptureSource() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["TOOLBOX_OCR_TEST_MODEL_DIR"],
              let imagePath = environment["TOOLBOX_OCR_TEST_IMAGE"]
        else { throw XCTSkip("Set the local PaddleOCR model and sample image paths") }
        let imageURL = URL(fileURLWithPath: imagePath)
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else { return XCTFail("Unable to decode the OCR sample image") }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-scroll-source-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ScrollCaptureStripStore(initialImage: image, rootDirectory: root)
        let scrollSource = try store.makeImageSource()
        let engine = try LocalPaddleOCREngine(
            modelDirectory: URL(fileURLWithPath: modelPath, isDirectory: true),
            provider: .cpu
        )

        let direct = try await engine.recognize(image: image)
        let fromScrollSource = try await engine.recognize(source: scrollSource)

        let directLines = Set(direct.lines.map(\.text))
        let scrollLines = Set(fromScrollSource.lines.map(\.text))
        let matchingLineCount = directLines.intersection(scrollLines).count
        XCTAssertGreaterThanOrEqual(
            matchingLineCount,
            max(1, directLines.count * 3 / 4),
            "Direct OCR:\n\(direct.plainText)\n\nScroll source OCR:\n\(fromScrollSource.plainText)"
        )
    }
}
