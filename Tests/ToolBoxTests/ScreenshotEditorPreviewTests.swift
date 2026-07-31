import CoreGraphics
import XCTest
@testable import ToolBox

final class ScreenshotEditorPreviewTests: XCTestCase {
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

    private func redPixelCount(in image: CGImage, row: Int) -> Int {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { return 0 }
        return (0..<image.width).filter { x in
            let offset = row * image.bytesPerRow + x * 4
            return bytes[offset] > 200 && bytes[offset + 1] < 40 && bytes[offset + 2] < 40
        }.count
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
