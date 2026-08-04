import CoreGraphics
import XCTest
@testable import ToolBox

final class ScreenshotImageComposerTests: XCTestCase {
    func testSingleFramePreservesRasterizedPixelOrientation() throws {
        let original = try rowImage(
            width: 4,
            colors: [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)]
        )
        let imageSize = CGSize(width: original.width, height: original.height)
        let geometry = DisplayCaptureGeometry(
            displayID: 1,
            globalFramePoints: CGRect(origin: .zero, size: imageSize),
            pixelSize: imageSize
        )

        let composed = try ScreenshotImageComposer.compose(
            selection: geometry.globalFramePoints,
            frames: [DisplayCaptureFrame(geometry: geometry, image: original)]
        )
        let originalPixels = try PaddleOCRImagePreprocessor.rasterizedImage(image: original)
        let composedPixels = try PaddleOCRImagePreprocessor.rasterizedImage(image: composed)

        XCTAssertEqual(composedPixels.pixels, originalPixels.pixels)
    }

    func testMixedScaleFramesComposeAtMaximumScaleAndPreserveGap() throws {
        let red = try solidImage(width: 200, height: 200, red: 255, green: 0, blue: 0)
        let blue = try solidImage(width: 100, height: 100, red: 0, green: 0, blue: 255)
        let frames = [
            DisplayCaptureFrame(
                geometry: .init(
                    displayID: 1,
                    globalFramePoints: CGRect(x: 0, y: 0, width: 100, height: 100),
                    pixelSize: CGSize(width: 200, height: 200)
                ),
                image: red
            ),
            DisplayCaptureFrame(
                geometry: .init(
                    displayID: 2,
                    globalFramePoints: CGRect(x: 150, y: 0, width: 100, height: 100),
                    pixelSize: CGSize(width: 100, height: 100)
                ),
                image: blue
            ),
        ]

        let image = try ScreenshotImageComposer.compose(
            selection: CGRect(x: 0, y: 0, width: 250, height: 100),
            frames: frames
        )

        XCTAssertEqual(image.width, 500)
        XCTAssertEqual(image.height, 200)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
        XCTAssertEqual(try pixel(in: image, x: 50, y: 50), [255, 0, 0, 255])
        XCTAssertEqual(try pixel(in: image, x: 250, y: 50), [0, 0, 0, 0])
        XCTAssertEqual(try pixel(in: image, x: 450, y: 50), [0, 0, 255, 255])
    }

    func testSelectionOutsideFrozenFramesIsRejected() throws {
        let frame = DisplayCaptureFrame(
            geometry: .init(
                displayID: 1,
                globalFramePoints: CGRect(x: 0, y: 0, width: 10, height: 10),
                pixelSize: CGSize(width: 10, height: 10)
            ),
            image: try solidImage(width: 10, height: 10, red: 0, green: 0, blue: 0)
        )

        XCTAssertThrowsError(try ScreenshotImageComposer.compose(
            selection: CGRect(x: 20, y: 20, width: 5, height: 5),
            frames: [frame]
        )) {
            XCTAssertEqual($0 as? ScreenshotCaptureError, .noIntersectingDisplays)
        }
    }

    private func solidImage(
        width: Int,
        height: Int,
        red: UInt8,
        green: UInt8,
        blue: UInt8
    ) throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestImageError.creationFailed
        }
        context.setFillColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw TestImageError.creationFailed }
        return image
    }

    private func rowImage(
        width: Int,
        colors: [(UInt8, UInt8, UInt8)]
    ) throws -> CGImage {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * colors.count * 4)
        for (red, green, blue) in colors {
            for _ in 0..<width {
                pixels.append(contentsOf: [red, green, blue, 255])
            }
        }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(
                  width: width,
                  height: colors.count,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw TestImageError.creationFailed
        }
        return image
    }

    private func pixel(in image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestImageError.creationFailed
        }
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return bytes
    }

    private enum TestImageError: Error {
        case creationFailed
    }
}
