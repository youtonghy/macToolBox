import AppKit
import SwiftUI
import ImageIO
import CoreGraphics
import XCTest
@testable import ToolBoxCore

final class SimilarPixelEraserTests: XCTestCase {
    func testSimilarNeighborsFlattenButStrongBoundarySurvives() throws {
        let source = try makeSource([100, 110, 240, 250], width: 4)
        let patch = try erase(source, sensitivity: 5)
        XCTAssertEqual(red(patch.image), [105, 105, 245, 245])
        XCTAssertEqual(red(source.image), [100, 110, 240, 250])
    }

    func testZeroSensitivityPreservesAndHigherSensitivityMerges() throws {
        let source = try makeSource([100, 110, 240, 250], width: 4)
        XCTAssertEqual(red(try erase(source, sensitivity: 0).image), [100, 110, 240, 250])
        XCTAssertEqual(red(try erase(source, sensitivity: 100).image), [175, 175, 175, 175])
    }

    func testFixedSeedPreventsGradientChaining() throws {
        let source = try makeSource([0, 20, 40, 60], width: 4)
        XCTAssertEqual(red(try erase(source, sensitivity: 10).image), [10, 10, 50, 50])
    }

    func testDiagonalsAreNotConnected() throws {
        let source = try makeSource([100, 250, 250, 110], width: 2)
        XCTAssertEqual(red(try erase(source, sensitivity: 5).image), [100, 250, 250, 110])
    }

    func testAlphaAndTransparentBarrier() throws {
        let source = try makeSource([100, 0, 110, 120], width: 4, alpha: [255, 0, 255, 128])
        let bytes = rgba(try erase(source, sensitivity: 100).image)
        XCTAssertEqual(stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }, [255, 0, 255, 128])
        XCTAssertEqual(bytes[0], 100)
        XCTAssertEqual(bytes[8], 115, accuracy: 1)
        XCTAssertEqual(bytes[12], 58, accuracy: 1)
    }

    func testPatchOrientationOutsideSelectionAndBandedExport() throws {
        let source = try makeSource([0, 0, 0, 0, 0, 100, 110, 0, 0, 200, 210, 0, 0, 0, 0, 0], width: 4)
        let rect = CGRect(x: 1, y: 1, width: 2, height: 2)
        let patch = try SimilarPixelEraser().process(source: source, rect: rect, sensitivity: 5)
        var state = AnnotationEditorState(document: ScreenshotDocument(baseImage: source))
        try AnnotationCommandReducer.reduce(state: &state, command: .add(ScreenshotAnnotation(payload: .similarPixels(rect: rect, patch: patch), style: .default)))
        let renderer = AnnotationRenderer()
        let expected: [UInt8] = [0, 0, 0, 0, 0, 105, 105, 0, 0, 205, 205, 0, 0, 0, 0, 0]
        XCTAssertEqual(red(try renderer.render(document: state.document)), expected)
        var bands: [UInt8] = []
        for y in 0..<4 {
            bands += red(try renderer.renderBand(document: state.document, pixelRect: CGRect(x: 0, y: y, width: 4, height: 1)))
        }
        XCTAssertEqual(bands, expected)
        let builder = ScreenshotEditorPreviewBuilder()
        let preview = try builder.makeBasePreview(document: state.document)
        XCTAssertEqual(red(try builder.render(document: state.document, preview: preview)), expected)
        try AnnotationCommandReducer.reduce(state: &state, command: .undo)
        XCTAssertEqual(red(try renderer.render(document: state.document)), red(source.image))
        try AnnotationCommandReducer.reduce(state: &state, command: .redo)
        XCTAssertEqual(red(try renderer.render(document: state.document)), expected)
    }

    func testOversizedImageRejectedBeforeReadingSource() throws {
        let source = OversizedSource()
        XCTAssertThrowsError(try SimilarPixelEraser().process(source: source, rect: CGRect(origin: .zero, size: source.pixelSize), sensitivity: 15)) {
            XCTAssertTrue($0 is SimilarPixelEraseError)
        }
    }

    func testInvalidSensitivityRejected() throws {
        let source = try makeSource([100], width: 1)
        for sensitivity in [-1.0, 101, .nan] {
            XCTAssertThrowsError(try erase(source, sensitivity: sensitivity))
        }
    }

    func testLongScreenshotScaledPreviewUsesOriginalPixelResult() throws {
        var gray = [UInt8](repeating: 240, count: 100 * 10_000)
        for row in 4900..<5000 {
            for x in 0..<100 { gray[row * 100 + x] = x % 2 == 0 ? 100 : 110 }
        }
        let source = try makeSource(gray, width: 100)
        let rect = CGRect(origin: .zero, size: source.pixelSize)
        let patch = try SimilarPixelEraser().process(source: source, rect: rect, sensitivity: 5)
        let document = ScreenshotDocument(baseImage: source, annotations: [
            ScreenshotAnnotation(payload: .similarPixels(rect: rect, patch: patch), style: .default)
        ])
        let builder = ScreenshotEditorPreviewBuilder(maximumPixelDimension: 1000)
        let preview = try builder.makeBasePreview(document: document)
        let rendered = try builder.render(document: document, preview: preview)
        XCTAssertEqual(rendered.width, 10)
        XCTAssertEqual(rendered.height, 1000)
        XCTAssertEqual(red(rendered)[495 * 10 + 5], 105)
        XCTAssertEqual(red(rendered)[480 * 10 + 5], 240)
        XCTAssertEqual(red(try patch.source.copyPixels(in: CGRect(x: 0, y: 4950, width: 100, height: 1))), [UInt8](repeating: 105, count: 100))
    }

    func testPNGExportUsesSamePatch() throws {
        let source = try makeSource([100, 110, 240, 250], width: 2)
        let patch = try erase(source, sensitivity: 5)
        let document = ScreenshotDocument(baseImage: source, annotations: [
            ScreenshotAnnotation(payload: .similarPixels(rect: CGRect(origin: .zero, size: source.pixelSize), patch: patch), style: .default)
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("similar-pixels-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try ScreenshotPNGExporter(renderer: AnnotationRenderer(maximumBandBytes: 8)).export(document: document, to: url)
        let decoded = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(red(try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))), [105, 105, 245, 245])
    }

    func testHistoryCountsSharedPatchesOnceAndRejectsWithoutChangingState() throws {
        let source = try makeSource([UInt8](repeating: 100, count: 1024 * 1024), width: 1024)
        let rect = CGRect(origin: .zero, size: source.pixelSize)
        var state = AnnotationEditorState(document: ScreenshotDocument(baseImage: source), pixelHistoryByteLimit: 64 * 1_024 * 1_024)
        let shared = ScreenshotPixelPatch(image: source.image)
        for _ in 0..<20 {
            try AnnotationCommandReducer.reduce(state: &state, command: .add(
                ScreenshotAnnotation(payload: .similarPixels(rect: rect, patch: shared), style: .default)
            ))
        }
        for _ in 0..<15 {
            try AnnotationCommandReducer.reduce(state: &state, command: .add(
                ScreenshotAnnotation(payload: .similarPixels(rect: rect, patch: ScreenshotPixelPatch(image: source.image)), style: .default)
            ))
        }
        let before = state.document.annotations
        XCTAssertThrowsError(try AnnotationCommandReducer.reduce(state: &state, command: .add(
            ScreenshotAnnotation(payload: .similarPixels(rect: rect, patch: ScreenshotPixelPatch(image: source.image)), style: .default)
        )))
        XCTAssertEqual(state.document.annotations, before)
        try AnnotationCommandReducer.reduce(state: &state, command: .undo)
        // Adding after undo releases redo-only allocations.
        XCTAssertNoThrow(try AnnotationCommandReducer.reduce(state: &state, command: .add(
            ScreenshotAnnotation(payload: .similarPixels(rect: rect, patch: ScreenshotPixelPatch(image: source.image)), style: .default)
        )))
    }

    @MainActor
    func testLatestSensitivityPreviewApplyUndoAndCancel() async throws {
        let source = try makeSource([100, 110, 240, 250], width: 4)
        let model = try makeModel(source)
        defer { model.cancelBackgroundWork() }
        model.beginErase()
        model.eraseSensitivity = 0
        model.eraseSensitivity = 100
        for _ in 0..<200 where model.isErasing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isErasing)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(red(model.renderedImage), [175, 175, 175, 175])
        XCTAssertFalse(model.canUndo)
        model.isComparingErase = true
        XCTAssertEqual(red(model.displayedImage), [100, 110, 240, 250])
        model.isComparingErase = false
        XCTAssertEqual(red(model.displayedImage), [175, 175, 175, 175])
        model.applyErase()
        XCTAssertFalse(model.hasPendingErase)
        XCTAssertTrue(model.canUndo)
        model.undo()
        XCTAssertEqual(red(model.renderedImage), [100, 110, 240, 250])
        model.redo()
        XCTAssertEqual(red(model.renderedImage), [175, 175, 175, 175])
        model.eraseSensitivity = 3
        model.beginErase()
        XCTAssertEqual(model.eraseSensitivity, 100)
        model.eraseSensitivity = 5
        for _ in 0..<200 where model.isErasing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(red(model.renderedImage), [105, 105, 245, 245])
        model.applyErase()
        model.undo()
        XCTAssertEqual(red(model.renderedImage), [175, 175, 175, 175])
        model.beginErase()
        model.cancelErase()
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertFalse(model.hasPendingErase)
        XCTAssertFalse(model.isErasing)
        XCTAssertEqual(red(model.renderedImage), [175, 175, 175, 175])
    }

    @MainActor
    func testClosingCancelsWorkerBeforeSourceCleanup() async throws {
        let model = try makeModel(makeSource([100, 110], width: 2))
        model.beginErase()
        let worker = try XCTUnwrap(model.cancelBackgroundWork())
        do {
            _ = try await worker.value
            XCTFail("Cancelled work must exit")
        } catch is CancellationError { }
        XCTAssertNil(model.erasePatch)
    }

    @MainActor
    func testEditorLayoutSnapshot() async throws {
        let gray: [UInt8] = (0..<16384).map { index in
            let base = index / 128 < 64 ? 100 : 240
            return UInt8(base + index % 8)
        }
        let source = try makeSource(gray, width: 128)
        let model = try makeModel(source)
        defer { model.cancelBackgroundWork() }
        for stage in ["collapsed", "erase"] {
            if stage == "erase" {
                model.beginErase()
                for _ in 0..<200 where model.isErasing { try await Task.sleep(nanoseconds: 10_000_000) }
            }
            for width in [1120, 820] {
                let view = NSHostingView(rootView: ScreenshotEditorView(model: model).background(Color(nsColor: .windowBackgroundColor)))
                view.frame = CGRect(x: 0, y: 0, width: width, height: width == 820 ? 540 : 700)
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "Screenshot toolbar \(stage) \(width)"
                attachment.lifetime = .keepAlways
                add(attachment)
                try png.write(to: URL(fileURLWithPath: "/tmp/macToolBox-toolbar-\(stage)-\(width).png"))
            }
        }
        XCTAssertNil(model.errorMessage)
    }

    func testWholeImageEffectStaysBelowAnnotationsAndReplacesPreviousAdjustment() throws {
        let source = try makeSource([100, 110, 240, 250], width: 4)
        let rect = CGRect(origin: .zero, size: source.pixelSize)
        let line = ScreenshotAnnotation(payload: .line(start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 4, y: 0.5)), style: .default)
        var state = AnnotationEditorState(document: ScreenshotDocument(baseImage: source, annotations: [line]))
        let first = ScreenshotAnnotation(payload: .similarPixels(rect: rect, patch: try erase(source, sensitivity: 100)), style: .default)
        try AnnotationCommandReducer.reduce(state: &state, command: .setPixelEffect(first))
        XCTAssertEqual(state.document.annotations, [first, line])
        let second = ScreenshotAnnotation(payload: .similarPixels(rect: rect, patch: try erase(source, sensitivity: 5)), style: .default)
        try AnnotationCommandReducer.reduce(state: &state, command: .setPixelEffect(second))
        XCTAssertEqual(state.document.annotations, [second, line])
        let image = try AnnotationRenderer().render(document: state.document)
        let bytes = rgba(image)
        XCTAssertEqual(Array(bytes[0..<4]), [255, 0, 0, 255])
        try AnnotationCommandReducer.reduce(state: &state, command: .undo)
        XCTAssertEqual(state.document.annotations, [first, line])
    }

    func testCancellationDuringPixelLoadingExitsWithoutPublishingResult() async throws {
        let loaded = expectation(description: "First source band loaded")
        loaded.assertForOverFulfill = false
        let source = WholeImageFixtureSource(width: 3840, height: 2160)
        let task = Task.detached {
            try SimilarPixelEraser().process(source: source, sensitivity: 100) { progress in
                if progress > 0 && progress < 0.16 { loaded.fulfill() }
            }
        }
        await fulfillment(of: [loaded], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must stop work before publishing a result")
        } catch is CancellationError { }
    }

    func testZeroSensitivityReportsNoPixelChangesAndPreservesAlphaBytes() throws {
        let source = try makeSource([10, 110, 210, 250], width: 2, alpha: [17, 50, 128, 255])
        let patch = try SimilarPixelEraser().process(source: source, sensitivity: 0)
        XCTAssertEqual(patch.changedPixelCount, 0)
        XCTAssertEqual(rgba(patch.image), rgba(source.image))
    }

    func testFourKImageProcessesAllPixelsWithBoundedSourceReads() throws {
        let source = WholeImageFixtureSource(width: 3840, height: 2160)
        let patch = try SimilarPixelEraser().process(source: source, sensitivity: 100)
        XCTAssertEqual(patch.image.width, 3840)
        XCTAssertEqual(patch.image.height, 2160)
        XCTAssertEqual(patch.changedPixelCount, 3840 * 2160)
        XCTAssertEqual(red(try patch.source.copyPixels(in: CGRect(x: 3839, y: 2159, width: 1, height: 1))), [105])
        XCTAssertLessThanOrEqual(source.maximumReadBytes, 8 * 1_024 * 1_024)
        XCTAssertGreaterThan(source.readCount, 1)
        XCTAssertEqual(patch.preview?.baseImage.width, 2048)
    }

    func testFileBackedScreenshotKeepsOrientationAcrossProcessingBands() throws {
        let source = try makeSource([10, 10, 30, 30, 60, 60, 90, 90], width: 2)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pixel-orientation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ScrollCaptureStripStore(initialImage: source.image, rootDirectory: root)
        let fileSource = try store.makeImageSource()
        let patch = try SimilarPixelEraser(sourceBandBytes: 8).process(source: fileSource, sensitivity: 0)
        XCTAssertEqual(red(patch.image), red(source.image))
        let document = ScreenshotDocument(baseImage: fileSource)
        let builder = ScreenshotEditorPreviewBuilder(maximumBandBytes: 8)
        let preview = try builder.makeBasePreview(document: document)
        XCTAssertEqual(red(preview.baseImage), red(source.image))
        var renderedBands: [UInt8] = []
        for y in 0..<4 {
            renderedBands += red(try AnnotationRenderer(maximumBandBytes: 8).renderBand(
                document: document, pixelRect: CGRect(x: 0, y: y, width: 2, height: 1)))
        }
        XCTAssertEqual(renderedBands, red(source.image))
    }

    func testRegionsRemainContinuousAcrossSourceBands() throws {
        let source = try makeSource((0..<6400).map { UInt8(100 + $0 % 10) }, width: 64)
        let first = try SimilarPixelEraser(sourceBandBytes: 64 * 4 * 7).process(source: source, sensitivity: 5)
        let second = try SimilarPixelEraser().process(source: source, sensitivity: 5)
        XCTAssertEqual(red(first.image), red(second.image))
        XCTAssertEqual(Set(red(first.image)), [105])
    }

    @MainActor
    private func makeModel(_ source: CGImageScreenshotSource) throws -> ScreenshotEditorModel {
        let document = ScreenshotDocument(baseImage: source)
        return try ScreenshotEditorModel(document: document,
                                         preview: ScreenshotEditorPreviewBuilder().makeBasePreview(document: document),
                                         ocrService: PixelTestOCRService(),
                                         ocrSettingsStore: OCRSettingsStore(key: "test.pixel.erase.\(UUID())"))
    }

    private func erase(_ source: CGImageScreenshotSource, sensitivity: Double) throws -> ScreenshotPixelPatch {
        try SimilarPixelEraser().process(source: source, rect: CGRect(origin: .zero, size: source.pixelSize), sensitivity: sensitivity)
    }

    private func makeSource(_ gray: [UInt8], width: Int, alpha: [UInt8]? = nil) throws -> CGImageScreenshotSource {
        var bytes: [UInt8] = []
        for (i, value) in gray.enumerated() {
            let a = alpha?[i] ?? 255
            let premultiplied = UInt8((Int(value) * Int(a) + 127) / 255)
            bytes += [premultiplied, premultiplied, premultiplied, a]
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: gray.count / width, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return CGImageScreenshotSource(image: image)
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        let data = image.dataProvider!.data! as Data
        return Array(data)
    }

    private func red(_ image: CGImage) -> [UInt8] {
        let bytes = rgba(image)
        return (0..<image.height).flatMap { y in (0..<image.width).map { bytes[y * image.bytesPerRow + $0 * 4] } }
    }
}

private final class OversizedSource: ScreenshotImageSource, @unchecked Sendable {
    let id = UUID()
    let pixelSize = CGSize(width: 16384, height: 16384)
    func copyPixels(in rect: CGRect) throws -> CGImage {
        XCTFail("Must reject before allocating source pixels")
        throw AnnotationError.invalidGeometry
    }
}

private struct PixelTestOCRService: OCRFeatureServing {
    func availableSelections() async throws -> [OCRModelSelection] { [] }
    func descriptor(for selection: OCRModelSelection) async throws -> OCRModelDescriptor { throw CancellationError() }
    func install(selection: OCRModelSelection, userConsented: Bool) async throws -> URL { throw CancellationError() }
    func recognize(source: ScreenshotImageSource, settings: OCRSettings) async throws -> OCRResult { throw CancellationError() }
}

private final class WholeImageFixtureSource: ScreenshotImageSource, @unchecked Sendable {
    let id = UUID()
    let pixelSize: CGSize
    private(set) var maximumReadBytes = 0
    private(set) var readCount = 0

    init(width: Int, height: Int) { pixelSize = CGSize(width: width, height: height) }

    func copyPixels(in rect: CGRect) throws -> CGImage {
        let width = Int(rect.width), height = Int(rect.height)
        let byteCount = width * height * 4
        maximumReadBytes = max(maximumReadBytes, byteCount)
        readCount += 1
        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { bytes in
            let pointer = bytes.bindMemory(to: UInt8.self)
            for i in 0..<(width * height) {
                let value: UInt8 = i % 2 == 0 ? 100 : 110
                pointer[i * 4] = value; pointer[i * 4 + 1] = value; pointer[i * 4 + 2] = value; pointer[i * 4 + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
}
