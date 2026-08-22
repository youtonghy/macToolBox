import CoreGraphics
import XCTest
@testable import ToolBoxCore

final class ScreenshotCanvasInteractionTests: XCTestCase {
    func testAspectFitTransformRoundTripsImagePoints() throws {
        let transform = try ScreenshotCanvasTransform(
            imageSize: CGSize(width: 1_000, height: 500),
            viewportSize: CGSize(width: 800, height: 800)
        )

        XCTAssertEqual(transform.contentRect, CGRect(x: 0, y: 200, width: 800, height: 400))
        let viewPoint = transform.viewPoint(forImagePoint: CGPoint(x: 250, y: 100))
        XCTAssertEqual(viewPoint.x, 200, accuracy: 0.001)
        XCTAssertEqual(viewPoint.y, 280, accuracy: 0.001)
        let imagePoint = try XCTUnwrap(transform.imagePoint(forViewPoint: viewPoint))
        XCTAssertEqual(imagePoint.x, 250, accuracy: 0.001)
        XCTAssertEqual(imagePoint.y, 100, accuracy: 0.001)
    }

    func testTransformRejectsLetterboxAndClampsDragPoint() throws {
        let transform = try ScreenshotCanvasTransform(
            imageSize: CGSize(width: 1_000, height: 500),
            viewportSize: CGSize(width: 800, height: 800)
        )

        XCTAssertNil(transform.imagePoint(forViewPoint: CGPoint(x: 400, y: 100)))
        XCTAssertEqual(
            transform.clampedImagePoint(forViewPoint: CGPoint(x: 900, y: 900)),
            CGPoint(x: 1_000, y: 500)
        )
    }

    func testDraftBuilderStandardizesDraggedRects() throws {
        let payload = try AnnotationDraftBuilder.payload(
            tool: .rectangle,
            start: CGPoint(x: 80, y: 60),
            current: CGPoint(x: 20, y: 10),
            points: []
        )

        XCTAssertEqual(payload, .rectangle(CGRect(x: 20, y: 10, width: 60, height: 50)))
    }

    func testDraftBuilderCreatesFreehandTextAndMarkerPayloads() throws {
        let points = [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)]
        XCTAssertEqual(
            try AnnotationDraftBuilder.payload(
                tool: .pen,
                start: points[0],
                current: points[1],
                points: points
            ),
            .stroke(points: points, isHighlighter: false)
        )
        XCTAssertEqual(
            try AnnotationDraftBuilder.payload(
                tool: .highlighter,
                start: points[0],
                current: points[1],
                points: points
            ),
            .stroke(points: points, isHighlighter: true)
        )
        XCTAssertEqual(
            try AnnotationDraftBuilder.payload(
                tool: .text,
                start: CGPoint(x: 10, y: 20),
                current: CGPoint(x: 10, y: 20),
                points: [],
                text: "Note"
            ),
            .text(TextAnnotation(text: "Note", origin: CGPoint(x: 10, y: 20), fontName: "Helvetica", fontSize: 24))
        )
        XCTAssertEqual(
            try AnnotationDraftBuilder.payload(
                tool: .numberedMarker,
                start: CGPoint(x: 10, y: 20),
                current: CGPoint(x: 10, y: 20),
                points: [],
                markerNumber: 3
            ),
            .numberedMarker(center: CGPoint(x: 10, y: 20), number: 3)
        )
    }

    func testDraftBuilderRejectsDegenerateShapesAndMissingText() {
        XCTAssertThrowsError(
            try AnnotationDraftBuilder.payload(
                tool: .arrow,
                start: CGPoint(x: 10, y: 10),
                current: CGPoint(x: 10, y: 10),
                points: []
            )
        )
        XCTAssertThrowsError(
            try AnnotationDraftBuilder.payload(
                tool: .text,
                start: .zero,
                current: .zero,
                points: []
            )
        )
    }
}
