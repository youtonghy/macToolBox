import CoreGraphics
import Foundation

enum ScreenshotAnnotationTool: String, CaseIterable, Identifiable, Sendable {
    case rectangle
    case ellipse
    case arrow
    case pen
    case highlighter
    case text
    case mosaic
    case numberedMarker

    var id: String { rawValue }
}

struct ScreenshotCanvasTransform: Equatable, Sendable {
    let imageSize: CGSize
    let viewportSize: CGSize
    let scale: CGFloat
    let contentRect: CGRect

    init(imageSize: CGSize, viewportSize: CGSize) throws {
        guard imageSize.width.isFinite,
              imageSize.height.isFinite,
              viewportSize.width.isFinite,
              viewportSize.height.isFinite,
              imageSize.width > 0,
              imageSize.height > 0,
              viewportSize.width > 0,
              viewportSize.height > 0
        else {
            throw AnnotationError.invalidGeometry
        }
        self.imageSize = imageSize
        self.viewportSize = viewportSize
        scale = min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height)
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        contentRect = CGRect(
            x: (viewportSize.width - fittedSize.width) / 2,
            y: (viewportSize.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    func imagePoint(forViewPoint point: CGPoint) -> CGPoint? {
        guard contentRect.contains(point) else { return nil }
        return CGPoint(
            x: (point.x - contentRect.minX) / scale,
            y: (point.y - contentRect.minY) / scale
        )
    }

    func clampedImagePoint(forViewPoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(imageSize.width, max(0, (point.x - contentRect.minX) / scale)),
            y: min(imageSize.height, max(0, (point.y - contentRect.minY) / scale))
        )
    }

    func viewPoint(forImagePoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: contentRect.minX + point.x * scale,
            y: contentRect.minY + point.y * scale
        )
    }
}

enum AnnotationDraftBuilder {
    static func payload(
        tool: ScreenshotAnnotationTool,
        start: CGPoint,
        current: CGPoint,
        points: [CGPoint],
        text: String? = nil,
        markerNumber: Int = 1
    ) throws -> ScreenshotAnnotationPayload {
        let dragRect = CGRect(
            x: start.x,
            y: start.y,
            width: current.x - start.x,
            height: current.y - start.y
        ).standardized
        switch tool {
        case .rectangle:
            try requireArea(dragRect)
            return .rectangle(dragRect)
        case .ellipse:
            try requireArea(dragRect)
            return .ellipse(dragRect)
        case .arrow:
            guard hypot(current.x - start.x, current.y - start.y) >= 1 else {
                throw AnnotationError.invalidGeometry
            }
            return .arrow(start: start, end: current, headLength: 16)
        case .pen:
            guard !points.isEmpty else { throw AnnotationError.invalidGeometry }
            return .stroke(points: points, isHighlighter: false)
        case .highlighter:
            guard !points.isEmpty else { throw AnnotationError.invalidGeometry }
            return .stroke(points: points, isHighlighter: true)
        case .text:
            guard let text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw AnnotationError.invalidText
            }
            return .text(
                TextAnnotation(text: text, origin: start, fontName: "Helvetica", fontSize: 24)
            )
        case .mosaic:
            try requireArea(dragRect)
            return .mosaic(rect: dragRect, blockSize: 12)
        case .numberedMarker:
            guard markerNumber > 0 else { throw AnnotationError.invalidGeometry }
            return .numberedMarker(center: start, number: markerNumber)
        }
    }

    private static func requireArea(_ rect: CGRect) throws {
        guard rect.width >= 1, rect.height >= 1 else {
            throw AnnotationError.invalidGeometry
        }
    }
}
