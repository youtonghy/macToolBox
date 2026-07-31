import CoreGraphics
import XCTest
@testable import ToolBox

final class AnnotationCommandReducerTests: XCTestCase {
    func testAddUndoRedoPreservesBaseImageIdentity() throws {
        let source = try makeSource()
        var state = AnnotationEditorState(document: ScreenshotDocument(baseImage: source))
        let annotation = rectangle(id: UUID(), rect: CGRect(x: 10, y: 20, width: 50, height: 30))
        try AnnotationCommandReducer.reduce(state: &state, command: .add(annotation))
        try AnnotationCommandReducer.reduce(state: &state, command: .undo)
        try AnnotationCommandReducer.reduce(state: &state, command: .redo)
        XCTAssertEqual(state.document.baseImage.id, source.id)
        XCTAssertEqual(state.document.annotations, [annotation])
    }

    func testUpdateDeleteReorderAndUnknownID() throws {
        let first = rectangle(id: UUID(), rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        let second = rectangle(id: UUID(), rect: CGRect(x: 20, y: 0, width: 10, height: 10))
        var state = AnnotationEditorState(document: ScreenshotDocument(baseImage: try makeSource(), annotations: [first, second]))
        var updated = first
        updated.payload = .ellipse(CGRect(x: 1, y: 1, width: 8, height: 8))
        try AnnotationCommandReducer.reduce(state: &state, command: .update(updated))
        try AnnotationCommandReducer.reduce(state: &state, command: .reorder(id: second.id, to: 0))
        try AnnotationCommandReducer.reduce(state: &state, command: .delete(updated.id))
        XCTAssertEqual(state.document.annotations, [second])
        XCTAssertThrowsError(try AnnotationCommandReducer.reduce(state: &state, command: .delete(UUID()))) {
            XCTAssertEqual($0 as? AnnotationError, .unknownAnnotation)
        }
    }

    func testNewEditInvalidatesRedoAndRejectsInvalidValues() throws {
        var state = AnnotationEditorState(document: ScreenshotDocument(baseImage: try makeSource()))
        let first = rectangle(id: UUID(), rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        try AnnotationCommandReducer.reduce(state: &state, command: .add(first))
        try AnnotationCommandReducer.reduce(state: &state, command: .undo)
        try AnnotationCommandReducer.reduce(state: &state, command: .add(rectangle(id: UUID(), rect: CGRect(x: 20, y: 20, width: 10, height: 10))))
        XCTAssertThrowsError(try AnnotationCommandReducer.reduce(state: &state, command: .redo)) {
            XCTAssertEqual($0 as? AnnotationError, .historyUnavailable)
        }
        XCTAssertThrowsError(try AnnotationCommandReducer.reduce(state: &state, command: .add(rectangle(id: UUID(), rect: CGRect(x: 0, y: 0, width: 0, height: 10)))))
        let emptyText = ScreenshotAnnotation(payload: .text(TextAnnotation(text: "", origin: .zero, fontName: "Helvetica", fontSize: 12)), style: .default)
        XCTAssertThrowsError(try AnnotationCommandReducer.reduce(state: &state, command: .add(emptyText)))
    }

    func testRejectsInvalidPayloadGeometryAndParameters() throws {
        let source = try makeSource()
        var state = AnnotationEditorState(document: ScreenshotDocument(baseImage: source))
        let invalidAnnotations = [
            ScreenshotAnnotation(
                payload: .line(start: CGPoint(x: -1, y: 10), end: CGPoint(x: 20, y: 20)),
                style: .default
            ),
            ScreenshotAnnotation(
                payload: .arrow(start: .zero, end: CGPoint(x: 20, y: 20), headLength: 0),
                style: .default
            ),
            ScreenshotAnnotation(
                payload: .arrow(start: CGPoint(x: 20, y: 20), end: CGPoint(x: 20, y: 20), headLength: 10),
                style: .default
            ),
            ScreenshotAnnotation(payload: .stroke(points: [], isHighlighter: false), style: .default),
            ScreenshotAnnotation(
                payload: .mosaic(rect: CGRect(x: 0, y: 0, width: 20, height: 20), blockSize: 0),
                style: .default
            ),
            ScreenshotAnnotation(
                payload: .numberedMarker(center: CGPoint(x: 10, y: 10), number: 0),
                style: .default
            ),
        ]

        for annotation in invalidAnnotations {
            XCTAssertThrowsError(try AnnotationCommandReducer.reduce(state: &state, command: .add(annotation))) {
                XCTAssertEqual($0 as? AnnotationError, .invalidGeometry)
            }
        }
        XCTAssertTrue(state.document.annotations.isEmpty)
        XCTAssertTrue(state.undoStack.isEmpty)
    }

    func testRejectsInvalidStyleAndTransform() throws {
        var state = AnnotationEditorState(document: ScreenshotDocument(baseImage: try makeSource()))
        var invalidColor = rectangle(id: UUID(), rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        invalidColor.style.color.red = 2
        XCTAssertThrowsError(try AnnotationCommandReducer.reduce(state: &state, command: .add(invalidColor))) {
            XCTAssertEqual($0 as? AnnotationError, .invalidStyle)
        }

        var invalidTransform = rectangle(id: UUID(), rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        invalidTransform.transform = CGAffineTransform(scaleX: 0, y: 1)
        XCTAssertThrowsError(try AnnotationCommandReducer.reduce(state: &state, command: .add(invalidTransform))) {
            XCTAssertEqual($0 as? AnnotationError, .invalidGeometry)
        }

        var overflowingTransform = rectangle(id: UUID(), rect: CGRect(x: 1, y: 1, width: 10, height: 10))
        overflowingTransform.transform = CGAffineTransform(
            a: .greatestFiniteMagnitude,
            b: 0,
            c: 0,
            d: .greatestFiniteMagnitude,
            tx: 0,
            ty: 0
        )
        XCTAssertThrowsError(try AnnotationCommandReducer.reduce(state: &state, command: .add(overflowingTransform))) {
            XCTAssertEqual($0 as? AnnotationError, .invalidGeometry)
        }

        var translatedOutOfBounds = rectangle(id: UUID(), rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        translatedOutOfBounds.transform = CGAffineTransform(translationX: 500, y: 0)
        XCTAssertThrowsError(try AnnotationCommandReducer.reduce(state: &state, command: .add(translatedOutOfBounds))) {
            XCTAssertEqual($0 as? AnnotationError, .invalidGeometry)
        }
    }

    func testRejectsDuplicateAnnotationID() throws {
        let annotation = rectangle(id: UUID(), rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        var state = AnnotationEditorState(document: ScreenshotDocument(baseImage: try makeSource()))
        try AnnotationCommandReducer.reduce(state: &state, command: .add(annotation))

        XCTAssertThrowsError(try AnnotationCommandReducer.reduce(state: &state, command: .add(annotation))) {
            XCTAssertEqual($0 as? AnnotationError, .duplicateAnnotation)
        }
        XCTAssertEqual(state.document.annotations, [annotation])
    }

    func testInvalidEditDoesNotCreateHistoryOrInvalidateRedo() throws {
        var state = AnnotationEditorState(document: ScreenshotDocument(baseImage: try makeSource()))
        let valid = rectangle(id: UUID(), rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        try AnnotationCommandReducer.reduce(state: &state, command: .add(valid))
        try AnnotationCommandReducer.reduce(state: &state, command: .undo)

        let invalid = rectangle(id: UUID(), rect: CGRect(x: 500, y: 0, width: 10, height: 10))
        XCTAssertThrowsError(try AnnotationCommandReducer.reduce(state: &state, command: .add(invalid)))
        try AnnotationCommandReducer.reduce(state: &state, command: .redo)

        XCTAssertEqual(state.document.annotations, [valid])
    }

    func testImageSourceRejectsInvalidAndOutOfBoundsCrops() throws {
        let source = try makeSource()
        XCTAssertNoThrow(try source.copyPixels(in: CGRect(x: 10, y: 10, width: 20, height: 20)))
        XCTAssertThrowsError(try source.copyPixels(in: CGRect(x: -1, y: 0, width: 10, height: 10))) {
            XCTAssertEqual($0 as? AnnotationError, .invalidGeometry)
        }
        XCTAssertThrowsError(try source.copyPixels(in: CGRect(x: 0, y: 0, width: 0, height: 10))) {
            XCTAssertEqual($0 as? AnnotationError, .invalidGeometry)
        }
    }

    func testHistoryCapEvictsOldestCommand() throws {
        var state = AnnotationEditorState(document: ScreenshotDocument(baseImage: try makeSource()), historyLimit: 2)
        for x in 0..<3 {
            try AnnotationCommandReducer.reduce(state: &state, command: .add(rectangle(id: UUID(), rect: CGRect(x: x * 10, y: 0, width: 5, height: 5))))
        }
        try AnnotationCommandReducer.reduce(state: &state, command: .undo)
        try AnnotationCommandReducer.reduce(state: &state, command: .undo)
        XCTAssertThrowsError(try AnnotationCommandReducer.reduce(state: &state, command: .undo))
        XCTAssertEqual(state.document.annotations.count, 1)
    }

    private func rectangle(id: UUID, rect: CGRect) -> ScreenshotAnnotation {
        ScreenshotAnnotation(id: id, payload: .rectangle(rect), style: .default)
    }

    private func makeSource() throws -> CGImageScreenshotSource {
        guard let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let image = context.makeImage() else { throw TestError.image }
        return CGImageScreenshotSource(image: image)
    }

    private enum TestError: Error { case image }
}
