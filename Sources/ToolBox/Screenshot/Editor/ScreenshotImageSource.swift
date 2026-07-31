import CoreGraphics
import Foundation

protocol ScreenshotImageSource: AnyObject, Sendable {
    var id: UUID { get }
    var pixelSize: CGSize { get }
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
