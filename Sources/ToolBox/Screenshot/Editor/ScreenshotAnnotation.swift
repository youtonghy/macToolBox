import CoreGraphics
import Foundation

struct AnnotationColor: Equatable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat
}

struct AnnotationStyle: Equatable, Sendable {
    var color: AnnotationColor
    var lineWidth: CGFloat
    var opacity: CGFloat

    static let `default` = AnnotationStyle(
        color: AnnotationColor(red: 1, green: 0, blue: 0, alpha: 1),
        lineWidth: 3,
        opacity: 1
    )
}

struct TextAnnotation: Equatable, Sendable {
    var text: String
    var origin: CGPoint
    var fontName: String
    var fontSize: CGFloat
}

enum ScreenshotAnnotationPayload: Equatable, Sendable {
    case rectangle(CGRect)
    case ellipse(CGRect)
    case line(start: CGPoint, end: CGPoint)
    case arrow(start: CGPoint, end: CGPoint, headLength: CGFloat)
    case stroke(points: [CGPoint], isHighlighter: Bool)
    case text(TextAnnotation)
    case mosaic(rect: CGRect, blockSize: Int)
    case numberedMarker(center: CGPoint, number: Int)
}
struct ScreenshotAnnotation: Equatable, Identifiable, Sendable {
    let id: UUID
    var payload: ScreenshotAnnotationPayload
    var style: AnnotationStyle
    var transform: CGAffineTransform

    init(
        id: UUID = UUID(),
        payload: ScreenshotAnnotationPayload,
        style: AnnotationStyle,
        transform: CGAffineTransform = .identity
    ) {
        self.id = id
        self.payload = payload
        self.style = style
        self.transform = transform
    }
}

enum AnnotationError: Error, Equatable {
    case unknownAnnotation
    case invalidGeometry
    case invalidStyle
    case invalidText
    case invalidIndex
    case historyUnavailable
}
