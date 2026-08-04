import CoreGraphics
import Foundation

enum OCRWorkerResultProjection {
    static let maximumMarkdownBytes = 16 * 1024 * 1024

    static func project(
        _ envelope: OCRWorkerResultEnvelope,
        imageSize: CGSize
    ) throws -> OCRResult {
        guard imageSize.width.isFinite,
              imageSize.height.isFinite,
              imageSize.width > 0,
              imageSize.height > 0
        else { throw OCRWorkerProtocolError.invalidResult }

        switch (envelope.pipeline, envelope.result) {
        case (.ppStructureV3, let .structured(blocks)):
            return .structured(StructuredOCRDocument(blocks: try blocks.map(projectStructuredBlock)))
        case (.paddleOCRVL, let .document(markdown, blocks)):
            guard markdown.utf8.count <= maximumMarkdownBytes else {
                throw OCRWorkerProtocolError.resultTooLarge
            }
            return .document(DocumentParseResult(
                markdown: markdown,
                blocks: try blocks.map {
                    try projectDocumentBlock($0, markdown: markdown)
                }
            ))
        default:
            throw OCRWorkerProtocolError.invalidResult
        }
    }

    private static func projectStructuredBlock(
        _ block: OCRWorkerResultBlock
    ) throws -> StructuredOCRDocument.Block {
        StructuredOCRDocument.Block(
            id: stableID(block.id),
            kind: structuredKind(block.kind),
            normalizedPolygon: try polygon(block.polygon),
            text: block.text,
            html: block.html,
            confidence: block.confidence
        )
    }

    private static func projectDocumentBlock(
        _ block: OCRWorkerResultBlock,
        markdown: String
    ) throws -> DocumentParseResult.Block {
        let range: Range<String.Index>?
        switch (block.markdownStart, block.markdownEnd) {
        case (nil, nil):
            range = nil
        case let (start?, end?):
            guard start >= 0,
                  end >= start,
                  end <= markdown.utf16.count
            else { throw OCRWorkerProtocolError.invalidMarkdownRange }
            let utf16 = markdown.utf16
            guard let lowerUTF16 = utf16.index(
                      utf16.startIndex,
                      offsetBy: start,
                      limitedBy: utf16.endIndex
                  ),
                  let upperUTF16 = utf16.index(
                      utf16.startIndex,
                      offsetBy: end,
                      limitedBy: utf16.endIndex
                  ),
                  let lower = String.Index(lowerUTF16, within: markdown),
                  let upper = String.Index(upperUTF16, within: markdown)
            else { throw OCRWorkerProtocolError.invalidMarkdownRange }
            range = lower..<upper
        default:
            throw OCRWorkerProtocolError.invalidMarkdownRange
        }
        return DocumentParseResult.Block(
            id: stableID(block.id),
            kind: block.kind,
            normalizedPolygon: try polygon(block.polygon),
            markdownRange: range,
            text: block.text
        )
    }

    private static func polygon(_ points: [OCRWorkerPoint]) throws -> [CGPoint] {
        guard points.count == 4,
              points.allSatisfy({
                  $0.x.isFinite && $0.y.isFinite
                      && (0...1).contains($0.x)
                      && (0...1).contains($0.y)
              })
        else { throw OCRWorkerProtocolError.invalidPolygon }
        let projected = points.map { CGPoint(x: $0.x, y: $0.y) }
        let area = projected.indices.reduce(0.0) { partial, index in
            let next = projected[(index + 1) % projected.count]
            return partial + projected[index].x * next.y - projected[index].y * next.x
        }
        guard abs(area) > 0.000001 else { throw OCRWorkerProtocolError.invalidPolygon }
        return projected
    }

    private static func structuredKind(_ kind: String) -> StructuredOCRDocument.Block.Kind {
        switch kind.lowercased() {
        case "title", "heading", "doc_title": .title
        case "paragraph", "text", "text_block": .paragraph
        case "image", "figure", "figure_title": .image
        case "table": .table
        default: .other
        }
    }

    private static func stableID(_ value: String?) -> UUID {
        guard let value, let id = UUID(uuidString: value) else { return UUID() }
        return id
    }
}
