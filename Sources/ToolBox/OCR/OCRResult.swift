import CoreGraphics
import Foundation

enum OCRResultError: Error, Equatable {
    case emptyText
    case invalidConfidence
    case invalidPolygon
}

struct OCRTextLine: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let confidence: Double
    let normalizedPolygon: [CGPoint]

    init(
        id: UUID = UUID(),
        text: String,
        confidence: Double,
        normalizedPolygon: [CGPoint]
    ) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OCRResultError.emptyText
        }
        guard confidence.isFinite, (0...1).contains(confidence) else {
            throw OCRResultError.invalidConfidence
        }
        guard normalizedPolygon.count == 4,
              normalizedPolygon.allSatisfy({ point in
                  point.x.isFinite && point.y.isFinite
                      && (0...1).contains(point.x)
                      && (0...1).contains(point.y)
              })
        else {
            throw OCRResultError.invalidPolygon
        }
        self.id = id
        self.text = text
        self.confidence = confidence
        self.normalizedPolygon = normalizedPolygon
    }

    var bounds: CGRect {
        normalizedPolygon.reduce(CGRect.null) { partial, point in
            partial.union(CGRect(origin: point, size: .zero))
        }
    }
}

struct TextOCRDocument: Equatable, Sendable {
    let lines: [OCRTextLine]

    init(lines: [OCRTextLine]) {
        self.lines = lines.enumerated().sorted { lhs, rhs in
            let left = lhs.element.bounds
            let right = rhs.element.bounds
            let rowTolerance = max(left.height, right.height) * 0.5
            if abs(left.midY - right.midY) > rowTolerance {
                return left.minY < right.minY
            }
            if left.minX != right.minX { return left.minX < right.minX }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    var plainText: String { lines.map(\.text).joined(separator: "\n") }
}

struct StructuredOCRDocument: Equatable, Sendable {
    struct Block: Identifiable, Equatable, Sendable {
        enum Kind: String, Equatable, Sendable {
            case title, paragraph, image, table, other
        }

        let id: UUID
        let kind: Kind
        let normalizedPolygon: [CGPoint]
        let text: String?
    }

    let blocks: [Block]
}

struct DocumentParseResult: Equatable, Sendable {
    struct Block: Identifiable, Equatable, Sendable {
        let id: UUID
        let kind: String
        let normalizedPolygon: [CGPoint]
        let markdownRange: Range<String.Index>?
    }

    let markdown: String
    let blocks: [Block]
}

enum OCRResult: Equatable, Sendable {
    case text(TextOCRDocument)
    case structured(StructuredOCRDocument)
    case document(DocumentParseResult)

    var plainText: String {
        switch self {
        case let .text(value): value.plainText
        case let .structured(value): value.blocks.compactMap(\.text).joined(separator: "\n")
        case let .document(value): value.markdown
        }
    }
}
