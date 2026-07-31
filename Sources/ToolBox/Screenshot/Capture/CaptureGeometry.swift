import CoreGraphics

struct DisplayCaptureGeometry: Equatable {
    let displayID: CGDirectDisplayID
    let globalFramePoints: CGRect
    let pixelSize: CGSize
}

struct DisplayCaptureFragment: Equatable {
    let displayID: CGDirectDisplayID
    let globalIntersectionPoints: CGRect
    let sourcePixels: CGRect
}

enum CaptureGeometryError: Error, Equatable {
    case invalidSelection
    case invalidDisplayGeometry(CGDirectDisplayID)
    case noIntersectingDisplays
}

enum CaptureGeometry {
    static func fragments(
        selection: CGRect,
        displays: [DisplayCaptureGeometry]
    ) throws -> [DisplayCaptureFragment] {
        guard isFinite(selection), selection.width > 0, selection.height > 0 else {
            throw CaptureGeometryError.invalidSelection
        }

        for display in displays {
            guard isFinite(display.globalFramePoints),
                  isFinite(display.pixelSize),
                  display.globalFramePoints.width > 0,
                  display.globalFramePoints.height > 0,
                  display.pixelSize.width > 0,
                  display.pixelSize.height > 0 else {
                throw CaptureGeometryError.invalidDisplayGeometry(display.displayID)
            }
        }

        let fragments = displays.compactMap { display -> DisplayCaptureFragment? in
            let intersection = selection.intersection(display.globalFramePoints)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
                return nil
            }

            return DisplayCaptureFragment(
                displayID: display.displayID,
                globalIntersectionPoints: intersection,
                sourcePixels: sourcePixels(for: intersection, on: display)
            )
        }
        .sorted(by: fragmentOrder)

        guard !fragments.isEmpty else {
            throw CaptureGeometryError.noIntersectingDisplays
        }
        return fragments
    }

    private static func sourcePixels(
        for intersection: CGRect,
        on display: DisplayCaptureGeometry
    ) -> CGRect {
        let xScale = display.pixelSize.width / display.globalFramePoints.width
        let yScale = display.pixelSize.height / display.globalFramePoints.height
        let minimumX = (intersection.minX - display.globalFramePoints.minX) * xScale
        let minimumY = (display.globalFramePoints.maxY - intersection.maxY) * yScale
        let maximumX = (intersection.maxX - display.globalFramePoints.minX) * xScale
        let maximumY = (display.globalFramePoints.maxY - intersection.minY) * yScale

        let x = clamp(minimumX.rounded(.down), maximum: display.pixelSize.width)
        let y = clamp(minimumY.rounded(.down), maximum: display.pixelSize.height)
        let maxX = clamp(maximumX.rounded(.up), maximum: display.pixelSize.width)
        let maxY = clamp(maximumY.rounded(.up), maximum: display.pixelSize.height)

        return CGRect(x: x, y: y, width: maxX - x, height: maxY - y)
    }

    private static func clamp(_ value: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(value, 0), maximum)
    }

    private static func fragmentOrder(
        _ lhs: DisplayCaptureFragment,
        _ rhs: DisplayCaptureFragment
    ) -> Bool {
        if lhs.globalIntersectionPoints.minX != rhs.globalIntersectionPoints.minX {
            return lhs.globalIntersectionPoints.minX < rhs.globalIntersectionPoints.minX
        }
        if lhs.globalIntersectionPoints.minY != rhs.globalIntersectionPoints.minY {
            return lhs.globalIntersectionPoints.minY < rhs.globalIntersectionPoints.minY
        }
        return lhs.displayID < rhs.displayID
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.size.width.isFinite
            && rect.size.height.isFinite
    }

    private static func isFinite(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite
    }
}
