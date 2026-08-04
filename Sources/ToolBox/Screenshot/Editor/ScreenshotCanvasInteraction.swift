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

struct OCRSelectionState: Equatable, Sendable {
    private(set) var isFiltering = false
    private(set) var selectedLineIDs: Set<UUID> = []

    mutating func replace<S: Sequence>(with lineIDs: S) where S.Element == UUID {
        isFiltering = true
        selectedLineIDs = Set(lineIDs)
    }

    mutating func toggle(_ lineID: UUID) {
        isFiltering = true
        if selectedLineIDs.contains(lineID) {
            selectedLineIDs.remove(lineID)
        } else {
            selectedLineIDs.insert(lineID)
        }
    }

    mutating func toggleBatch<S: Sequence>(_ lineIDs: S) where S.Element == UUID {
        let touched = Set(lineIDs)
        guard !touched.isEmpty else { return }
        isFiltering = true
        if touched.isSubset(of: selectedLineIDs) {
            selectedLineIDs.subtract(touched)
        } else {
            selectedLineIDs.formUnion(touched)
        }
    }

    mutating func reset() {
        isFiltering = false
        selectedLineIDs.removeAll()
    }

    func displayedDocument(from document: TextOCRDocument) -> TextOCRDocument {
        guard isFiltering else { return document }
        return TextOCRDocument(lines: document.lines.filter { selectedLineIDs.contains($0.id) })
    }
}

enum OCRSelectionGeometry {
    static func lineID(at normalizedPoint: CGPoint, in lines: [OCRTextLine]) -> UUID? {
        for line in lines.reversed() where contains(normalizedPoint, polygon: line.normalizedPolygon) {
            return line.id
        }
        return nil
    }

    static func lineIDs(
        intersecting normalizedRect: CGRect,
        in lines: [OCRTextLine]
    ) -> [UUID] {
        let rect = normalizedRect.standardized
        guard !rect.isNull, !rect.isEmpty else { return [] }
        return lines.compactMap { line in
            line.bounds.intersects(rect) ? line.id : nil
        }
    }

    private static func contains(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard let first = polygon.first else { return false }
        let path = CGMutablePath()
        path.move(to: first)
        path.addLines(between: Array(polygon.dropFirst()))
        path.closeSubpath()
        return path.contains(point, using: .winding)
    }
}

enum ScreenshotZoomAdjuster {
    static let range = 1.0...4.0
    static let wheelStep = 0.25

    static func adjust(zoom: Double, wheelDeltaY: CGFloat) -> Double {
        guard wheelDeltaY != 0 else { return clamp(zoom) }
        return clamp(zoom + (wheelDeltaY > 0 ? wheelStep : -wheelStep))
    }

    static func pinch(startZoom: Double, magnification: CGFloat) -> Double {
        guard magnification.isFinite else { return clamp(startZoom) }
        return clamp(startZoom * Double(magnification))
    }

    static func shouldZoom(hasPreciseScrollingDeltas: Bool) -> Bool {
        !hasPreciseScrollingDeltas
    }

    static func clamp(_ zoom: Double) -> Double {
        guard zoom.isFinite else { return range.lowerBound }
        return min(range.upperBound, max(range.lowerBound, zoom))
    }
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
