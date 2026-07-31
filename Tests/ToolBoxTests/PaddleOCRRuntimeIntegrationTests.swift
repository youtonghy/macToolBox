import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import ToolBox

final class PaddleOCRRuntimeIntegrationTests: XCTestCase {
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
}
