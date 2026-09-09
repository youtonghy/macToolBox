import CoreGraphics
import Foundation

protocol ScreenshotImageSource: AnyObject, Sendable {
    var id: UUID { get }
    var pixelSize: CGSize { get }
    /// Returns an upright CGImage whose provider rows run from the visual top to bottom.
    func copyPixels(in rect: CGRect) throws -> CGImage
}

final class CGImageScreenshotSource: ScreenshotImageSource, @unchecked Sendable {
    let id = UUID()
    let image: CGImage

    var pixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    init(image: CGImage) {
        self.image = image
    }

    func copyPixels(in rect: CGRect) throws -> CGImage {
        let imageBounds = CGRect(origin: .zero, size: pixelSize)
        guard rect.isFinite,
              rect.width > 0,
              rect.height > 0,
              imageBounds.contains(rect)
        else {
            throw AnnotationError.invalidGeometry
        }
        guard let crop = image.cropping(to: rect) else { throw AnnotationError.invalidGeometry }
        return crop
    }
}

private extension CGRect {
    var isFinite: Bool {
        origin.x.isFinite
            && origin.y.isFinite
            && width.isFinite
            && height.isFinite
    }
}

/// Scroll storage's crop Y is bottom-origin even though the returned provider is
/// upright. Normalize once at the editor boundary so every band agrees with a
/// single full-image read, without changing the capture/strip storage format.
func topLeftScreenshotSource(_ source: ScreenshotImageSource) -> ScreenshotImageSource {
    guard let scroll = source as? ScrollCaptureImageSource else { return source }
    return TopLeftScrollScreenshotSource(source: scroll)
}

private final class TopLeftScrollScreenshotSource: ScreenshotImageSource, @unchecked Sendable {
    let source: ScrollCaptureImageSource
    var id: UUID { source.id }
    var pixelSize: CGSize { source.pixelSize }

    init(source: ScrollCaptureImageSource) { self.source = source }

    func copyPixels(in rect: CGRect) throws -> CGImage {
        guard rect.isFinite, rect.width > 0, rect.height > 0,
              CGRect(origin: .zero, size: pixelSize).contains(rect) else { throw AnnotationError.invalidGeometry }
        return try source.copyPixels(in: CGRect(x: rect.minX, y: pixelSize.height - rect.maxY,
                                               width: rect.width, height: rect.height))
    }
}
