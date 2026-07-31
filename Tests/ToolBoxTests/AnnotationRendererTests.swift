import CoreGraphics
import ImageIO
import XCTest
@testable import ToolBox

final class AnnotationRendererTests: XCTestCase {
    func testRenderPreservesBaseAndAppliesAnnotationsInZOrder() throws {
        let base = try makeImage(width: 40, height: 30, color: (255, 255, 255, 255))
        let red = AnnotationStyle(
            color: AnnotationColor(red: 1, green: 0, blue: 0, alpha: 1),
            lineWidth: 8,
            opacity: 1
        )
        let blue = AnnotationStyle(
            color: AnnotationColor(red: 0, green: 0, blue: 1, alpha: 1),
            lineWidth: 8,
            opacity: 1
        )
        let document = ScreenshotDocument(
            baseImage: CGImageScreenshotSource(image: base),
            annotations: [
                ScreenshotAnnotation(payload: .line(start: CGPoint(x: 5, y: 15), end: CGPoint(x: 35, y: 15)), style: red),
                ScreenshotAnnotation(payload: .line(start: CGPoint(x: 20, y: 5), end: CGPoint(x: 20, y: 25)), style: blue),
            ]
        )

        let image = try AnnotationRenderer().render(document: document)

        XCTAssertEqual(try pixel(in: image, x: 2, y: 2), RGBA(255, 255, 255, 255))
        XCTAssertEqual(try pixel(in: image, x: 10, y: 15), RGBA(255, 0, 0, 255))
        XCTAssertEqual(try pixel(in: image, x: 20, y: 15), RGBA(0, 0, 255, 255))
    }

    func testMosaicSamplesImmutableBaseInsteadOfEarlierAnnotations() throws {
        let base = try makeSplitImage(width: 20, height: 10)
        let green = AnnotationStyle(
            color: AnnotationColor(red: 0, green: 1, blue: 0, alpha: 1),
            lineWidth: 6,
            opacity: 1
        )
        let document = ScreenshotDocument(
            baseImage: CGImageScreenshotSource(image: base),
            annotations: [
                ScreenshotAnnotation(payload: .line(start: CGPoint(x: 0, y: 5), end: CGPoint(x: 19, y: 5)), style: green),
                ScreenshotAnnotation(payload: .mosaic(rect: CGRect(x: 0, y: 0, width: 20, height: 10), blockSize: 10), style: .default),
            ]
        )

        let image = try AnnotationRenderer().render(document: document)

        XCTAssertEqual(try pixel(in: image, x: 5, y: 5), RGBA(255, 0, 0, 255))
        XCTAssertEqual(try pixel(in: image, x: 15, y: 5), RGBA(0, 0, 255, 255))
    }

    func testBandRenderingKeepsMosaicGridContinuous() throws {
        let base = try makeSplitImage(width: 20, height: 20)
        let annotation = ScreenshotAnnotation(
            payload: .mosaic(rect: CGRect(x: 0, y: 0, width: 20, height: 20), blockSize: 6),
            style: .default
        )
        let document = ScreenshotDocument(baseImage: CGImageScreenshotSource(image: base), annotations: [annotation])
        let renderer = AnnotationRenderer(maximumBandBytes: 1_000)

        let top = try renderer.renderBand(document: document, pixelRect: CGRect(x: 0, y: 0, width: 20, height: 10))
        let bottom = try renderer.renderBand(document: document, pixelRect: CGRect(x: 0, y: 10, width: 20, height: 10))

        XCTAssertEqual(try pixel(in: top, x: 2, y: 8), try pixel(in: bottom, x: 2, y: 2))
    }

    func testBandRenderingOnlyRequestsVisibleMosaicBlocks() throws {
        let source = RecordingImageSource(width: 100, height: 10_000)
        let annotation = ScreenshotAnnotation(
            payload: .mosaic(rect: CGRect(x: 0, y: 0, width: 100, height: 10_000), blockSize: 10),
            style: .default
        )
        let document = ScreenshotDocument(baseImage: source, annotations: [annotation])

        _ = try AnnotationRenderer().renderBand(
            document: document,
            pixelRect: CGRect(x: 0, y: 5_000, width: 100, height: 100)
        )

        XCTAssertEqual(source.requestCount, 2)
    }

    func testPNGExporterWritesDimensionsAndAlpha() throws {
        let base = try makeImage(width: 37, height: 19, color: (10, 20, 30, 128))
        let document = ScreenshotDocument(baseImage: CGImageScreenshotSource(image: base))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("annotation-export-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        try ScreenshotPNGExporter(renderer: AnnotationRenderer(maximumBandBytes: 256)).export(document: document, to: url)

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return XCTFail("Could not read exported PNG")
        }
        XCTAssertEqual(image.width, 37)
        XCTAssertEqual(image.height, 19)
        XCTAssertNotEqual(image.alphaInfo, .none)
        assertRGBAEqual(try pixel(in: image, x: 0, y: 0), RGBA(10, 20, 30, 128), accuracy: 1)
    }

    func testExporterRequestsNoSourceBandLargerThanConfiguredLimit() throws {
        let source = RecordingImageSource(width: 100, height: 60_000)
        let document = ScreenshotDocument(baseImage: source)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("annotation-tall-export-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        try ScreenshotPNGExporter(renderer: AnnotationRenderer(maximumBandBytes: 16 * 1_024 * 1_024))
            .export(document: document, to: url)

        XCTAssertLessThanOrEqual(source.maximumRequestedBytes, 16 * 1_024 * 1_024)
        XCTAssertGreaterThan(source.requestCount, 1)
    }

    func testExporterRejectsInvalidDimensionsAndConfiguredTotalCap() throws {
        let invalid = ScreenshotDocument(baseImage: InvalidSizeImageSource())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("annotation-invalid-export-\(UUID().uuidString).png")
        XCTAssertThrowsError(try ScreenshotPNGExporter().export(document: invalid, to: url)) {
            XCTAssertEqual($0 as? AnnotationRenderError, .invalidDimensions)
        }

        let tooLarge = ScreenshotDocument(baseImage: RecordingImageSource(width: 100, height: 100))
        XCTAssertThrowsError(
            try ScreenshotPNGExporter(maximumExportBytes: 1_000).export(document: tooLarge, to: url)
        ) {
            XCTAssertEqual($0 as? AnnotationRenderError, .exportTooLarge)
        }
    }

    private func makeImage(
        width: Int,
        height: Int,
        color: (UInt8, UInt8, UInt8, UInt8)
    ) throws -> CGImage {
        let context = try makeContext(width: width, height: height)
        context.setFillColor(
            red: CGFloat(color.0) / 255,
            green: CGFloat(color.1) / 255,
            blue: CGFloat(color.2) / 255,
            alpha: CGFloat(color.3) / 255
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw TestError.image }
        return image
    }

    private func makeSplitImage(width: Int, height: Int) throws -> CGImage {
        let context = try makeContext(width: width, height: height)
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        guard let image = context.makeImage() else { throw TestError.image }
        return image
    }

    private func makeContext(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestError.image
        }
        return context
    }

    private func pixel(in image: CGImage, x: Int, y: Int) throws -> RGBA {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            throw TestError.image
        }
        let offset = y * image.bytesPerRow + x * 4
        return RGBA(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }

    private struct RGBA: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8

        init(_ red: UInt8, _ green: UInt8, _ blue: UInt8, _ alpha: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }
    }

    private func assertRGBAEqual(_ actual: RGBA, _ expected: RGBA, accuracy: UInt8) {
        XCTAssertLessThanOrEqual(abs(Int(actual.red) - Int(expected.red)), Int(accuracy))
        XCTAssertLessThanOrEqual(abs(Int(actual.green) - Int(expected.green)), Int(accuracy))
        XCTAssertLessThanOrEqual(abs(Int(actual.blue) - Int(expected.blue)), Int(accuracy))
        XCTAssertLessThanOrEqual(abs(Int(actual.alpha) - Int(expected.alpha)), Int(accuracy))
    }

    private enum TestError: Error { case image }
}

private final class RecordingImageSource: ScreenshotImageSource {
    let id = UUID()
    let pixelSize: CGSize
    private(set) var maximumRequestedBytes = 0
    private(set) var requestCount = 0

    init(width: Int, height: Int) {
        pixelSize = CGSize(width: width, height: height)
    }

    func copyPixels(in rect: CGRect) throws -> CGImage {
        let width = Int(rect.width)
        let height = Int(rect.height)
        requestCount += 1
        maximumRequestedBytes = max(maximumRequestedBytes, width * height * 4)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw AnnotationError.invalidGeometry
        }
        return image
    }
}

private final class InvalidSizeImageSource: ScreenshotImageSource {
    let id = UUID()
    let pixelSize = CGSize(width: CGFloat.infinity, height: 10)

    func copyPixels(in rect: CGRect) throws -> CGImage {
        throw AnnotationError.invalidGeometry
    }
}
