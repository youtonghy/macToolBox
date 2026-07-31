import CoreGraphics
import Foundation

struct ScrollCaptureFrame: @unchecked Sendable {
    let image: CGImage
    let luma: LumaFrame
    let timestamp: TimeInterval

    func copyNewRows(previewRowCount: Int) throws -> CGImage {
        guard previewRowCount > 0, previewRowCount <= luma.height else {
            throw ScrollCaptureError.invalidStrip
        }
        let scaledRows = Double(previewRowCount) * Double(image.height) / Double(luma.height)
        let originalRows = min(image.height, max(1, Int(scaledRows.rounded(.up))))
        // CGImage crop coordinates are bottom-origin; forward scrolling reveals the bottom rows.
        let rect = CGRect(x: 0, y: 0, width: image.width, height: originalRows)
        guard let crop = image.cropping(to: rect) else { throw ScrollCaptureError.invalidStrip }
        return crop
    }
}

@MainActor
protocol ScrollCaptureFrameProviding: AnyObject {
    func captureInitialFrame(target: ScrollCaptureTargetSnapshot) async throws -> ScrollCaptureFrame
    func captureStableFrame(target: ScrollCaptureTargetSnapshot) async throws -> ScrollCaptureFrame
}

struct ScrollCaptureLumaConverter: Sendable {
    let maximumWidth: Int

    init(maximumWidth: Int = 128) {
        self.maximumWidth = max(16, maximumWidth)
    }

    func convert(_ image: CGImage) throws -> LumaFrame {
        guard image.width > 0, image.height > 0 else { throw ScrollCaptureError.invalidLumaFrame }
        let width = min(maximumWidth, image.width)
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  )
            else { return false }
            context.interpolationQuality = .medium
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw ScrollCaptureError.invalidLumaFrame }
        return try LumaFrame(width: width, height: height, pixels: pixels)
    }
}

@MainActor
final class DefaultScrollCaptureFrameProvider: ScrollCaptureFrameProviding {
    private let captureProvider: ScreenCaptureProviding
    private let converter: ScrollCaptureLumaConverter
    private let sampleCadence: Duration
    private let maximumSamples: Int

    init(
        captureProvider: ScreenCaptureProviding,
        converter: ScrollCaptureLumaConverter = ScrollCaptureLumaConverter(),
        sampleCadence: Duration = .milliseconds(120),
        maximumSamples: Int = 30
    ) {
        self.captureProvider = captureProvider
        self.converter = converter
        self.sampleCadence = sampleCadence
        self.maximumSamples = max(3, maximumSamples)
    }

    func captureInitialFrame(target: ScrollCaptureTargetSnapshot) async throws -> ScrollCaptureFrame {
        try await capture(target: target)
    }

    func captureStableFrame(target: ScrollCaptureTargetSnapshot) async throws -> ScrollCaptureFrame {
        var detector = FrameStabilityDetector()
        var last: ScrollCaptureFrame?
        for _ in 0..<maximumSamples {
            try Task.checkCancellation()
            let frame = try await capture(target: target)
            last = frame
            if try detector.observe(frame.luma, timestamp: frame.timestamp) == .stable {
                return frame
            }
            try await Task.sleep(for: sampleCadence)
        }
        guard let last else { throw ScrollCaptureError.captureFailed }
        return last
    }

    private func capture(target: ScrollCaptureTargetSnapshot) async throws -> ScrollCaptureFrame {
        let image = try await captureProvider.captureRegion(
            target.roiGlobal,
            displayID: target.displayID
        )
        let luma = try await Task.detached { [converter] in
            try converter.convert(image)
        }.value
        return ScrollCaptureFrame(
            image: image,
            luma: luma,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
    }
}
