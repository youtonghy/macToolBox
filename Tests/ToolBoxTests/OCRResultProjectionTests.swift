import CoreGraphics
import XCTest
@testable import ToolBox

final class OCRResultProjectionTests: XCTestCase {
    func testTextDocumentValidatesNormalizedPolygonsAndStableReadingOrder() throws {
        let lower = try OCRTextLine(
            id: UUID(),
            text: "second",
            confidence: 0.8,
            normalizedPolygon: polygon(x: 0.1, y: 0.6)
        )
        let upperRight = try OCRTextLine(
            id: UUID(),
            text: "right",
            confidence: 0.9,
            normalizedPolygon: polygon(x: 0.6, y: 0.1)
        )
        let upperLeft = try OCRTextLine(
            id: UUID(),
            text: "left",
            confidence: 0.95,
            normalizedPolygon: polygon(x: 0.1, y: 0.1)
        )

        let document = TextOCRDocument(lines: [lower, upperRight, upperLeft])

        XCTAssertEqual(document.lines.map(\.text), ["left", "right", "second"])
        XCTAssertEqual(OCRResult.text(document).plainText, "left\nright\nsecond")
    }

    func testTextLineRejectsMalformedGeometryConfidenceAndEmptyText() {
        XCTAssertThrowsError(try OCRTextLine(
            text: "x",
            confidence: 0.9,
            normalizedPolygon: [CGPoint(x: 0, y: 0)]
        )) { XCTAssertEqual($0 as? OCRResultError, .invalidPolygon) }

        XCTAssertThrowsError(try OCRTextLine(
            text: "x",
            confidence: 1.1,
            normalizedPolygon: polygon(x: 0, y: 0)
        )) { XCTAssertEqual($0 as? OCRResultError, .invalidConfidence) }

        XCTAssertThrowsError(try OCRTextLine(
            text: "   ",
            confidence: 0.9,
            normalizedPolygon: polygon(x: 0, y: 0)
        )) { XCTAssertEqual($0 as? OCRResultError, .emptyText) }

        XCTAssertThrowsError(try OCRTextLine(
            text: "x",
            confidence: 0.9,
            normalizedPolygon: polygon(x: 0.9, y: 0.9)
        )) { XCTAssertEqual($0 as? OCRResultError, .invalidPolygon) }
    }

    private func polygon(x: CGFloat, y: CGFloat) -> [CGPoint] {
        [
            CGPoint(x: x, y: y),
            CGPoint(x: x + 0.2, y: y),
            CGPoint(x: x + 0.2, y: y + 0.1),
            CGPoint(x: x, y: y + 0.1),
        ]
    }
}
