import CoreGraphics

struct DisplayCaptureFrame {
    let geometry: DisplayCaptureGeometry
    let image: CGImage
}

enum ScreenshotImageComposer {
    static func compose(selection: CGRect, frames: [DisplayCaptureFrame]) throws -> CGImage {
        try FrozenCaptureBudget.validate(pixelSizes: frames.map(\.geometry.pixelSize))
        for frame in frames {
            guard frame.image.width == Int(frame.geometry.pixelSize.width),
                  frame.image.height == Int(frame.geometry.pixelSize.height) else {
                throw ScreenshotCaptureError.invalidImageDimensions
            }
        }

        let geometries = frames.map(\.geometry)
        let fragments: [DisplayCaptureFragment]
        do {
            fragments = try CaptureGeometry.fragments(selection: selection, displays: geometries)
        } catch CaptureGeometryError.invalidSelection {
            throw ScreenshotCaptureError.invalidSelection
        } catch let CaptureGeometryError.invalidDisplayGeometry(displayID) {
            throw ScreenshotCaptureError.invalidDisplayGeometry(displayID)
        } catch CaptureGeometryError.noIntersectingDisplays {
            throw ScreenshotCaptureError.noIntersectingDisplays
        }

        let intersectingIDs = Set(fragments.map(\.displayID))
        let outputScale = frames
            .filter { intersectingIDs.contains($0.geometry.displayID) }
            .map { frame in
                max(
                    frame.geometry.pixelSize.width / frame.geometry.globalFramePoints.width,
                    frame.geometry.pixelSize.height / frame.geometry.globalFramePoints.height
                )
            }
            .max() ?? 1

        let width = try pixelDimension(selection.width * outputScale)
        let height = try pixelDimension(selection.height * outputScale)
        try FrozenCaptureBudget.validate(pixelSizes: [CGSize(width: width, height: height)])

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ScreenshotCaptureError.bitmapContextUnavailable
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let framesByID = Dictionary(uniqueKeysWithValues: frames.map { ($0.geometry.displayID, $0) })
        for fragment in fragments {
            guard let frame = framesByID[fragment.displayID] else {
                throw ScreenshotCaptureError.missingDisplayFrame(fragment.displayID)
            }
            guard let crop = frame.image.cropping(to: fragment.sourcePixels) else {
                throw ScreenshotCaptureError.imageCropFailed(fragment.displayID)
            }

            let destination = CGRect(
                x: (fragment.globalIntersectionPoints.minX - selection.minX) * outputScale,
                y: (selection.maxY - fragment.globalIntersectionPoints.maxY) * outputScale,
                width: fragment.globalIntersectionPoints.width * outputScale,
                height: fragment.globalIntersectionPoints.height * outputScale
            )
            context.interpolationQuality = .high
            context.draw(crop, in: destination)
        }

        guard let image = context.makeImage() else {
            throw ScreenshotCaptureError.bitmapContextUnavailable
        }
        return image
    }

    private static func pixelDimension(_ value: CGFloat) throws -> Int {
        guard value.isFinite, value > 0 else {
            throw ScreenshotCaptureError.invalidImageDimensions
        }
        let rounded = value.rounded(.up)
        guard rounded <= CGFloat(Int.max), let dimension = Int(exactly: rounded) else {
            throw ScreenshotCaptureError.invalidImageDimensions
        }
        return dimension
    }
}
