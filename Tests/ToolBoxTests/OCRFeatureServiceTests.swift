import CoreGraphics
import Foundation
import XCTest
@testable import ToolBox

final class OCRFeatureServiceTests: XCTestCase {
    func testDescriptorReportsSignedCatalogSizeAndAbsentState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-feature-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = OCRFeatureService(rootDirectory: root)

        let descriptor = try await service.descriptor(for: .tiny)

        XCTAssertEqual(descriptor.profile, .tiny)
        XCTAssertEqual(descriptor.downloadByteCount, 6_299_683)
        XCTAssertEqual(descriptor.state, .notInstalled)
    }

    @MainActor
    func testDescriptorLookupIsPartOfProtectedOCRLifecycle() async throws {
        let image = makeImage()
        let document = ScreenshotDocument(baseImage: CGImageScreenshotSource(image: image))
        let preview = try ScreenshotEditorPreviewBuilder().makeBasePreview(document: document)
        let service = DelayedOCRFeatureService()
        let model = try ScreenshotEditorModel(
            document: document,
            preview: preview,
            ocrService: service
        )

        model.requestOCR()

        XCTAssertTrue(model.isRecognizing)
        model.cancelOCR()
        for _ in 0..<100 where model.isRecognizing {
            await Task.yield()
        }
        XCTAssertFalse(model.isRecognizing)
    }

    private func makeImage() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }
}

private actor DelayedOCRFeatureService: OCRFeatureServing {
    func descriptor(for profile: PPOCRv6Profile) async throws -> OCRModelDescriptor {
        try await Task.sleep(for: .seconds(30))
        return OCRModelDescriptor(profile: profile, downloadByteCount: 1, state: .notInstalled)
    }

    func install(profile: PPOCRv6Profile, userConsented: Bool) async throws -> URL {
        throw CancellationError()
    }

    func recognize(
        source: ScreenshotImageSource,
        settings: OCRSettings
    ) async throws -> TextOCRDocument {
        throw CancellationError()
    }
}
