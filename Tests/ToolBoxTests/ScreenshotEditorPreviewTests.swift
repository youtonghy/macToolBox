import CoreGraphics
import XCTest
@testable import ToolBoxCore

final class ScreenshotEditorPreviewTests: XCTestCase {
    func testProductionCaptureRenderedPreviewPreservesTopToBottomOrientation() throws {
        let sourceImage = try verticallySplitImage(width: 40, height: 20)
        let imageSize = CGSize(width: sourceImage.width, height: sourceImage.height)
        let geometry = DisplayCaptureGeometry(
            displayID: 1,
            globalFramePoints: CGRect(origin: .zero, size: imageSize),
            pixelSize: imageSize
        )
        let captured = try ScreenshotImageComposer.compose(
            selection: geometry.globalFramePoints,
            frames: [DisplayCaptureFrame(geometry: geometry, image: sourceImage)]
        )
        let document = ScreenshotDocument(baseImage: CGImageScreenshotSource(image: captured))
        let builder = ScreenshotEditorPreviewBuilder(
            maximumPixelDimension: 40,
            maximumBandBytes: 40 * 20 * 4
        )

        let preview = try builder.makeBasePreview(document: document)
        let rendered = try builder.render(document: document, preview: preview)

        XCTAssertTrue(isRed(pixel(in: captured, x: 20, rowFromTop: 2)))
        XCTAssertTrue(isBlue(pixel(in: captured, x: 20, rowFromTop: 17)))
        XCTAssertTrue(isRed(pixel(in: preview.baseImage, x: 20, rowFromTop: 2)))
        XCTAssertTrue(isBlue(pixel(in: preview.baseImage, x: 20, rowFromTop: 17)))
        let top = pixel(in: rendered, x: 20, rowFromTop: 2)
        let bottom = pixel(in: rendered, x: 20, rowFromTop: 17)
        XCTAssertTrue(isRed(top), "top pixel: \(top)")
        XCTAssertTrue(isBlue(bottom), "bottom pixel: \(bottom)")
    }

    func testBasePreviewPreservesTopToBottomOrientation() throws {
        let sourceImage = try verticallySplitImage(width: 40, height: 20)
        let document = ScreenshotDocument(baseImage: CGImageScreenshotSource(image: sourceImage))

        let preview = try ScreenshotEditorPreviewBuilder(
            maximumPixelDimension: 40,
            maximumBandBytes: 40 * 4 * 4
        )
            .makeBasePreview(document: document)

        XCTAssertEqual(preview.baseImage.width, 40)
        XCTAssertEqual(preview.baseImage.height, 20)
        let top = pixel(in: preview.baseImage, x: 20, rowFromTop: 2)
        let bottom = pixel(in: preview.baseImage, x: 20, rowFromTop: 17)
        XCTAssertTrue(isRed(top), "top pixel: \(top)")
        XCTAssertTrue(isBlue(bottom), "bottom pixel: \(bottom)")
    }

    func testTallDocumentBuildsBoundedPreviewUsingBoundedSourceReads() throws {
        let source = PreviewRecordingImageSource(width: 1_000, height: 60_000)
        let document = ScreenshotDocument(baseImage: source)
        let builder = ScreenshotEditorPreviewBuilder(
            maximumPixelDimension: 2_000,
            maximumBandBytes: 400_000
        )

        let preview = try builder.makeBasePreview(document: document)

        XCTAssertEqual(preview.baseImage.width, 33)
        XCTAssertEqual(preview.baseImage.height, 2_000)
        XCTAssertEqual(preview.scale, 1.0 / 30.0, accuracy: 0.000_001)
        XCTAssertLessThanOrEqual(source.maximumRequestedBytes, 400_000)
        XCTAssertGreaterThan(source.requestCount, 1)
    }

    func testPreviewRenderScalesAnnotationCoordinatesAndStrokeWidth() throws {
        let source = PreviewRecordingImageSource(width: 400, height: 200)
        let style = AnnotationStyle(
            color: AnnotationColor(red: 1, green: 0, blue: 0, alpha: 1),
            lineWidth: 20,
            opacity: 1
        )
        let document = ScreenshotDocument(
            baseImage: source,
            annotations: [
                ScreenshotAnnotation(
                    payload: .line(start: CGPoint(x: 100, y: 100), end: CGPoint(x: 300, y: 100)),
                    style: style
                ),
            ]
        )
        let builder = ScreenshotEditorPreviewBuilder(maximumPixelDimension: 200)
        let preview = try builder.makeBasePreview(document: document)

        let rendered = try builder.render(document: document, preview: preview)

        XCTAssertEqual(rendered.width, 200)
        XCTAssertEqual(rendered.height, 100)
        XCTAssertGreaterThan(redPixelCount(in: rendered, row: 50), 90)
    }

    func testDefaultPreviewCanRenderImageLargerThanRenderBudget() throws {
        let source = PreviewRecordingImageSource(width: 2_049, height: 2_049)
        let document = ScreenshotDocument(baseImage: source)
        let builder = ScreenshotEditorPreviewBuilder()

        let preview = try builder.makeBasePreview(document: document)
        let rendered = try builder.render(document: document, preview: preview)

        XCTAssertEqual(rendered.width, 2_048)
        XCTAssertEqual(rendered.height, 2_048)
    }

    private func redPixelCount(in image: CGImage, row: Int) -> Int {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { return 0 }
        return (0..<image.width).filter { x in
            let offset = row * image.bytesPerRow + x * 4
            return bytes[offset] > 200 && bytes[offset + 1] < 40 && bytes[offset + 2] < 40
        }.count
    }

    private func verticallySplitImage(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                if row < height / 2 {
                    bytes[offset] = 255
                } else {
                    bytes[offset + 2] = 255
                }
                bytes[offset + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else { throw AnnotationError.invalidGeometry }
        return image
    }

    private func pixel(in image: CGImage, x: Int, rowFromTop: Int) -> [UInt8] {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { return [] }
        let offset = rowFromTop * image.bytesPerRow + x * 4
        return Array(UnsafeBufferPointer(start: bytes + offset, count: 4))
    }

    private func isRed(_ pixel: [UInt8]) -> Bool {
        pixel.count == 4 && pixel[0] > 240 && pixel[2] < 15
    }

    private func isBlue(_ pixel: [UInt8]) -> Bool {
        pixel.count == 4 && pixel[0] < 15 && pixel[2] > 240
    }
}

private final class PreviewRecordingImageSource: ScreenshotImageSource, @unchecked Sendable {
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
        ) else {
            throw AnnotationError.invalidGeometry
        }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw AnnotationError.invalidGeometry }
        return image
    }
}
