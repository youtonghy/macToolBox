import CoreGraphics
import CryptoKit
import Foundation
import XCTest
@testable import ToolBoxCore

final class OCRFeatureServiceTests: XCTestCase {
    func testSystemVisionRebaseMapsTileCoordinatesIntoFullImageSpace() throws {
        // Tile occupies rows 1280..<1380 of a 100×5000 long screenshot.
        let tile = CGRect(x: 0, y: 1_280, width: 100, height: 100)
        let fullSize = CGSize(width: 100, height: 5_000)
        let line = try OCRTextLine(
            text: "hello",
            confidence: 0.9,
            normalizedPolygon: [
                CGPoint(x: 0, y: 0),
                CGPoint(x: 1, y: 0),
                CGPoint(x: 1, y: 1),
                CGPoint(x: 0, y: 1),
            ]
        )

        let rebased = OCRFeatureService.rebased([line], from: tile, to: fullSize)

        XCTAssertEqual(rebased.count, 1)
        XCTAssertEqual(rebased[0].normalizedPolygon, [
            CGPoint(x: 0, y: 1_280.0 / 5_000.0),
            CGPoint(x: 1, y: 1_280.0 / 5_000.0),
            CGPoint(x: 1, y: 1_380.0 / 5_000.0),
            CGPoint(x: 0, y: 1_380.0 / 5_000.0),
        ])
    }

    func testSystemVisionDeduplicateDropsOverlapDuplicatesKeepsDistinct() throws {
        func line(_ text: String, y: CGFloat) throws -> OCRTextLine {
            try OCRTextLine(
                text: text,
                confidence: 0.9,
                normalizedPolygon: [
                    CGPoint(x: 0.1, y: y),
                    CGPoint(x: 0.5, y: y),
                    CGPoint(x: 0.5, y: y + 0.02),
                    CGPoint(x: 0.1, y: y + 0.02),
                ]
            )
        }

        let first = try line("dup", y: 0.5)
        let nearDuplicate = try line("dup", y: 0.501)   // same text, IoU > 0.5
        let elsewhere = try line("dup", y: 0.1)          // same text, no overlap
        let otherText = try line("other", y: 0.5)        // overlapping but different text

        let result = OCRFeatureService.deduplicated([first, nearDuplicate, elsewhere, otherText])

        XCTAssertEqual(result.map(\.text), ["dup", "dup", "other"])
    }

    func testDescriptorReportsSignedCatalogSizeAndAbsentState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-feature-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = OCRFeatureService(rootDirectory: root)

        let descriptor = try await service.descriptor(for: .tiny)

        XCTAssertEqual(descriptor.selection, OCRModelSelection(pipeline: .ppOCRv6, variantID: "tiny"))
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

    func testAdvancedDescriptorKeepsPipelineAndVariantIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-feature-advanced-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let selection = OCRModelSelection(pipeline: .paddleOCRVL, variantID: "v1.6")
        let manifest = OCRModelManifest(
            id: "paddleocr-vl-v1.6",
            pipeline: selection.pipeline,
            variantID: selection.variantID,
            displayName: "PaddleOCR-VL v1.6",
            version: "1.6-test",
            architectures: [.arm64],
            licenseResource: "PaddleOCR-NOTICE.txt",
            files: [
                OCRModelFileManifest(
                    relativePath: "vl/config.json",
                    url: immutableURL("vl/config.json"),
                    byteCount: 1,
                    sha256: String(repeating: "a", count: 64)
                ),
            ]
        )
        let service = OCRFeatureService(
            rootDirectory: root,
            catalogOverride: OCRModelCatalog(schemaVersion: 1, models: [manifest])
        )

        let descriptor = try await service.descriptor(for: selection)

        XCTAssertEqual(descriptor.selection, selection)
        XCTAssertEqual(descriptor.displayName, "PaddleOCR-VL v1.6")
    }

    func testAdvancedInstallUsesCatalogDownloadAndVerificationPath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-feature-advanced-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("verified advanced model".utf8)
        let file = OCRModelFileManifest(
            relativePath: "layout/inference.pdiparams",
            url: immutableURL("layout/inference.pdiparams"),
            byteCount: Int64(payload.count),
            sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        )
        let selection = OCRModelSelection(pipeline: .ppStructureV3)
        let manifest = OCRModelManifest(
            id: "pp-structure-v3-default",
            pipeline: selection.pipeline,
            variantID: selection.variantID,
            displayName: "PP-StructureV3",
            version: "3.7.0-test",
            architectures: [.arm64],
            licenseResource: "PaddleOCR-NOTICE.txt",
            files: [file]
        )
        let downloader = FeatureServiceFileDownloader(payloads: [file.url: payload])
        let service = OCRFeatureService(
            rootDirectory: root,
            catalogOverride: OCRModelCatalog(schemaVersion: 1, models: [manifest]),
            downloader: downloader
        )

        let descriptor = try await service.descriptor(for: selection)
        XCTAssertEqual(descriptor.downloadByteCount, Int64(payload.count))
        XCTAssertEqual(descriptor.state, .notInstalled)

        let directory = try await service.install(selection: selection, userConsented: true)

        let downloadCalls = await downloader.callCount
        XCTAssertEqual(downloadCalls, 1)
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent(file.relativePath)),
            payload
        )
        let installedDescriptor = try await service.descriptor(for: selection)
        XCTAssertEqual(installedDescriptor.state, .ready)
    }

    func testShippedAvailabilityExposesAdvancedModelsWhenWorkerIsBundled() async throws {
        let service = OCRFeatureService()

        let selections = try await service.availableSelections()

        XCTAssertEqual(Set(selections), Set(OCRPipelineID.allCases.flatMap { pipeline in
            pipeline.knownVariantIDs.map {
                OCRModelSelection(pipeline: pipeline, variantID: $0)
            }
        }))
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

private actor FeatureServiceFileDownloader: OCRModelFileDownloading {
    let payloads: [URL: Data]
    private(set) var callCount = 0

    init(payloads: [URL: Data]) {
        self.payloads = payloads
    }

    func download(_ url: URL) async throws -> URL {
        callCount += 1
        guard let payload = payloads[url] else { throw URLError(.fileDoesNotExist) }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-feature-download-\(UUID().uuidString)")
        try payload.write(to: output)
        return output
    }
}

private actor DelayedOCRFeatureService: OCRFeatureServing {
    func descriptor(for selection: OCRModelSelection) async throws -> OCRModelDescriptor {
        try await Task.sleep(for: .seconds(30))
        return OCRModelDescriptor(selection: selection, downloadByteCount: 1, state: .notInstalled)
    }

    func install(selection: OCRModelSelection, userConsented: Bool) async throws -> URL {
        throw CancellationError()
    }

    func recognize(
        source: ScreenshotImageSource,
        settings: OCRSettings
    ) async throws -> OCRResult {
        throw CancellationError()
    }
}
