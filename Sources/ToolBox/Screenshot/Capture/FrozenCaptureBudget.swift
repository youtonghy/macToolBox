import CoreGraphics

enum ScreenshotCaptureError: Error, Equatable {
    case invalidSelection
    case invalidDisplayGeometry(CGDirectDisplayID)
    case invalidImageDimensions
    case frozenFrameBudgetExceeded
    case noIntersectingDisplays
    case missingDisplayFrame(CGDirectDisplayID)
    case imageCropFailed(CGDirectDisplayID)
    case bitmapContextUnavailable
    case ownApplicationUnavailable
    case displayGeometryUnavailable(CGDirectDisplayID)
    case displayCaptureFailed(CGDirectDisplayID)
    case shareableContentUnavailable
    case displayTopologyChanged
}

enum FrozenCaptureBudget {
    static let maximumBytes = 768 * 1_024 * 1_024
    private static let bytesPerPixel = 4

    static func validate(pixelSizes: [CGSize]) throws {
        var aggregateBytes = 0
        for size in pixelSizes {
            guard size.width.isFinite,
                  size.height.isFinite,
                  size.width > 0,
                  size.height > 0,
                  let width = Int(exactly: size.width),
                  let height = Int(exactly: size.height) else {
                throw ScreenshotCaptureError.invalidImageDimensions
            }

            let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
            let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: bytesPerPixel)
            let (newAggregate, aggregateOverflow) = aggregateBytes.addingReportingOverflow(bytes)
            guard !pixelOverflow, !byteOverflow, !aggregateOverflow else {
                throw ScreenshotCaptureError.invalidImageDimensions
            }
            guard newAggregate <= maximumBytes else {
                throw ScreenshotCaptureError.frozenFrameBudgetExceeded
            }
            aggregateBytes = newAggregate
        }
    }
}
