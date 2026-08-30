import CoreGraphics
import XCTest
@testable import ToolBoxCore

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
        let first = try gray(in: strip, x: 0, y: 0)
        let last = try gray(in: strip, x: 0, y: 14)
        XCTAssertGreaterThan(first, 180)
        XCTAssertGreaterThan(last, 180)
        XCTAssertGreaterThan(first, last)
    }

    @MainActor
    func testCaptureStableFrameThrowsWhenNeverStable() async throws {
        let provider = DefaultScrollCaptureFrameProvider(
            captureProvider: AlternatingCaptureProvider(),
            sampleCadence: .zero,
            maximumSamples: 3
        )

        do {
            _ = try await provider.captureStableFrame(target: unstableTarget)
            XCTFail("Expected frameNeverStable")
        } catch let error as ScrollCaptureError {
            XCTAssertEqual(error, .frameNeverStable)
        }
    }

    private var unstableTarget: ScrollCaptureTargetSnapshot {
        ScrollCaptureTargetSnapshot(
            ownerPID: 42,
            windowID: 7,
            displayID: 1,
            topologyGeneration: 9,
            topologySignature: 123,
            roiGlobal: CGRect(x: 0, y: 0, width: 10, height: 10),
            windowGlobalFrame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
    }

    private func makeGradient(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            context.setFillColor(gray: CGFloat(y) / CGFloat(max(1, height - 1)), alpha: 1)
            context.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        return context.makeImage()!
    }

    private func gray(in image: CGImage, x: Int, y: Int) throws -> UInt8 {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            throw ScrollCaptureError.invalidStrip
        }
        return bytes[y * image.bytesPerRow + x * 4]
    }
}

/// Returns alternating black/white images so the stability detector never
/// reports a quiet sample.
@MainActor
private final class AlternatingCaptureProvider: ScreenCaptureProviding {
    private var counter = 0

    func captureDisplays() async throws -> [DisplayCaptureFrame] { [] }

    func captureRegion(_ region: CGRect, displayID: CGDirectDisplayID) async throws -> CGImage {
        counter += 1
        let gray: CGFloat = counter % 2 == 1 ? 0 : 1
        let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 8 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()!
    }
}
