import CoreGraphics
import XCTest
@testable import ToolBox

final class ScreenshotOCRSelectionTests: XCTestCase {
    func testSelectionInitiallyDisplaysFullDocumentWithoutSelectedBoxes() throws {
        let document = try makeDocument()
        let selection = OCRSelectionState()

        XCTAssertFalse(selection.isFiltering)
        XCTAssertTrue(selection.selectedLineIDs.isEmpty)
        XCTAssertEqual(selection.displayedDocument(from: document).plainText, "first\nsecond\nthird")
    }

    func testReplaceAndToggleSelectionPreserveDocumentReadingOrder() throws {
        let document = try makeDocument()
        var selection = OCRSelectionState()

        selection.replace(with: [lineID(3), lineID(1)])
        XCTAssertTrue(selection.isFiltering)
        XCTAssertEqual(selection.displayedDocument(from: document).plainText, "first\nthird")

        selection.toggle(lineID(2))
        XCTAssertEqual(selection.displayedDocument(from: document).plainText, "first\nsecond\nthird")

        selection.toggle(lineID(1))
        XCTAssertEqual(selection.displayedDocument(from: document).plainText, "second\nthird")
    }

    func testBatchToggleAddsTouchedLinesUnlessAllAreAlreadySelected() throws {
        let document = try makeDocument()
        var selection = OCRSelectionState()
        selection.replace(with: [lineID(1)])

        selection.toggleBatch([lineID(1), lineID(2)])
        XCTAssertEqual(selection.displayedDocument(from: document).plainText, "first\nsecond")

        selection.toggleBatch([lineID(1), lineID(2)])
        XCTAssertTrue(selection.isFiltering)
        XCTAssertTrue(selection.selectedLineIDs.isEmpty)
        XCTAssertTrue(selection.displayedDocument(from: document).plainText.isEmpty)
    }

    func testResetReturnsToFullDocumentWithoutChangingCachedResult() throws {
        let document = try makeDocument()
        var selection = OCRSelectionState()
        selection.replace(with: [lineID(2)])

        selection.reset()

        XCTAssertFalse(selection.isFiltering)
        XCTAssertTrue(selection.selectedLineIDs.isEmpty)
        XCTAssertEqual(selection.displayedDocument(from: document), document)
    }

    private func makeDocument() throws -> TextOCRDocument {
        TextOCRDocument(lines: [
            try makeLine(id: 3, text: "third", rect: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.1)),
            try makeLine(id: 1, text: "first", rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)),
            try makeLine(id: 2, text: "second", rect: CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.1)),
        ])
    }
}

final class ScreenshotOCRSelectionGeometryTests: XCTestCase {
    func testHitTestUsesThePolygonInsteadOfOnlyItsBounds() throws {
        let diamond = try OCRTextLine(
            id: lineID(1),
            text: "diamond",
            confidence: 0.9,
            normalizedPolygon: [
                CGPoint(x: 0.5, y: 0.2),
                CGPoint(x: 0.8, y: 0.5),
                CGPoint(x: 0.5, y: 0.8),
                CGPoint(x: 0.2, y: 0.5),
            ]
        )

        XCTAssertEqual(
            OCRSelectionGeometry.lineID(at: CGPoint(x: 0.5, y: 0.5), in: [diamond]),
            diamond.id
        )
        XCTAssertNil(OCRSelectionGeometry.lineID(at: CGPoint(x: 0.21, y: 0.21), in: [diamond]))
    }

    func testDragSelectionReturnsAllIntersectingBoxes() throws {
        let first = try makeLine(id: 1, text: "first", rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let second = try makeLine(id: 2, text: "second", rect: CGRect(x: 0.55, y: 0.55, width: 0.2, height: 0.2))
        let third = try makeLine(id: 3, text: "third", rect: CGRect(x: 0.8, y: 0.1, width: 0.1, height: 0.1))

        let ids = OCRSelectionGeometry.lineIDs(
            intersecting: CGRect(x: 0.25, y: 0.25, width: 0.4, height: 0.4),
            in: [first, second, third]
        )

        XCTAssertEqual(ids, [first.id, second.id])
    }
}

final class ScreenshotZoomAdjusterTests: XCTestCase {
    func testMouseWheelZoomUsesDirectionAndClampsToSupportedRange() {
        XCTAssertEqual(ScreenshotZoomAdjuster.adjust(zoom: 2, wheelDeltaY: 1), 2.25)
        XCTAssertEqual(ScreenshotZoomAdjuster.adjust(zoom: 2, wheelDeltaY: -1), 1.75)
        XCTAssertEqual(ScreenshotZoomAdjuster.adjust(zoom: 3.9, wheelDeltaY: 1), 4)
        XCTAssertEqual(ScreenshotZoomAdjuster.adjust(zoom: 1.1, wheelDeltaY: -1), 1)
    }

    func testPinchZoomUsesGestureStartValueAndClamps() {
        XCTAssertEqual(ScreenshotZoomAdjuster.pinch(startZoom: 2, magnification: 1.5), 3)
        XCTAssertEqual(ScreenshotZoomAdjuster.pinch(startZoom: 3, magnification: 2), 4)
        XCTAssertEqual(ScreenshotZoomAdjuster.pinch(startZoom: 2, magnification: 0.1), 1)
    }

    func testOnlyDiscreteMouseWheelEventsAreUsedForZoom() {
        XCTAssertTrue(ScreenshotZoomAdjuster.shouldZoom(hasPreciseScrollingDeltas: false))
        XCTAssertFalse(ScreenshotZoomAdjuster.shouldZoom(hasPreciseScrollingDeltas: true))
    }
}

private func makeLine(id: Int, text: String, rect: CGRect) throws -> OCRTextLine {
    try OCRTextLine(
        id: lineID(id),
        text: text,
        confidence: 0.9,
        normalizedPolygon: [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ]
    )
}

private func lineID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}
