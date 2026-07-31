import CoreGraphics
import XCTest
@testable import ToolBox

final class ScrollCaptureFrameProviderTests: XCTestCase {
    func testLumaConversionIsBoundedAndPreservesAspectRatio() throws {
        let image = makeGradient(width: 400, height: 200)
        let luma = try ScrollCaptureLumaConverter(maximumWidth: 100).convert(image)

        XCTAssertEqual(luma.width, 100)
        XCTAssertEqual(luma.height, 50)
        XCTAssertEqual(luma.pixels.count, 5_000)
    }

    func testOriginalNewRowsMapsPreviewOffsetAndCropsBottomRows() throws {
        let image = makeGradient(width: 10, height: 100)
        let frame = ScrollCaptureFrame(
            image: image,
            luma: try LumaFrame(width: 5, height: 20, pixels: Array(repeating: 0, count: 100)),
            timestamp: 1
        )

        let strip = try frame.copyNewRows(previewRowCount: 3)

        XCTAssertEqual(strip.width, 10)
        XCTAssertEqual(strip.height, 15)
    }

    private func makeGradient(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            context.setFillColor(gray: CGFloat(y) / CGFloat(max(1, height - 1)), alpha: 1)
            context.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        return context.makeImage()!
    }
}
