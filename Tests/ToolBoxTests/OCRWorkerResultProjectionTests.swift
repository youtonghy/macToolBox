import CoreGraphics
import XCTest
@testable import ToolBox

final class OCRWorkerResultProjectionTests: XCTestCase {
    func testProjectsStructureBlocksAsTypedBlocks() throws {
        let envelope = OCRWorkerResultEnvelope(
            taskID: "task-1",
            pipeline: .ppStructureV3,
            variantID: "default",
            result: .structured([
                OCRWorkerResultBlock(
                    id: "title-1",
                    kind: "title",
                    polygon: [
                        .init(x: 0.1, y: 0.1),
                        .init(x: 0.9, y: 0.1),
                        .init(x: 0.9, y: 0.2),
                        .init(x: 0.1, y: 0.2),
                    ],
                    text: "Report"
                ),
                OCRWorkerResultBlock(
                    id: "table-1",
                    kind: "table",
                    polygon: [
                        .init(x: 0.1, y: 0.3),
                        .init(x: 0.9, y: 0.3),
                        .init(x: 0.9, y: 0.8),
                        .init(x: 0.1, y: 0.8),
                    ],
                    text: nil,
                    html: "<table><tr><td>A</td></tr></table>"
                ),
            ])
        )

        let result = try OCRWorkerResultProjection.project(
            envelope,
            imageSize: CGSize(width: 1_000, height: 1_000)
        )

        guard case let .structured(document) = result else {
            return XCTFail("expected structured result")
        }
        XCTAssertEqual(document.blocks.map(\.kind), [.title, .table])
        XCTAssertEqual(document.blocks[0].text, "Report")
        XCTAssertEqual(document.blocks[1].html, "<table><tr><td>A</td></tr></table>")
        XCTAssertEqual(document.blocks[1].normalizedPolygon[2], CGPoint(x: 0.9, y: 0.8))
    }

    func testProjectsVLMarkdownAndSourceRanges() throws {
        let envelope = OCRWorkerResultEnvelope(
            taskID: "task-1",
            pipeline: .paddleOCRVL,
            variantID: "v1.6",
            result: .document(
                markdown: "# Report\n\nBody",
                blocks: [
                    OCRWorkerResultBlock(
                        id: "heading-1",
                        kind: "heading",
                        polygon: [
                            .init(x: 0.1, y: 0.1),
                            .init(x: 0.9, y: 0.1),
                            .init(x: 0.9, y: 0.2),
                            .init(x: 0.1, y: 0.2),
                        ],
                        text: nil,
                        markdownStart: 0,
                        markdownEnd: 9
                    ),
                ]
            )
        )

        let result = try OCRWorkerResultProjection.project(
            envelope,
            imageSize: CGSize(width: 1_000, height: 1_000)
        )

        guard case let .document(document) = result else {
            return XCTFail("expected document result")
        }
        XCTAssertEqual(document.markdown, "# Report\n\nBody")
        XCTAssertEqual(document.blocks.count, 1)
        XCTAssertEqual(document.blocks[0].kind, "heading")
        XCTAssertEqual(document.blocks[0].markdownRange.map { document.markdown[$0] }, "# Report\n")
    }

    func testRejectsInvalidPolygonInsteadOfClampingIt() throws {
        let envelope = OCRWorkerResultEnvelope(
            taskID: "task-1",
            pipeline: .ppStructureV3,
            variantID: "default",
            result: .structured([
                OCRWorkerResultBlock(
                    id: "bad",
                    kind: "paragraph",
                    polygon: [
                        .init(x: -0.1, y: 0.1),
                        .init(x: 0.9, y: 0.1),
                        .init(x: 0.9, y: 0.2),
                        .init(x: 0.1, y: 0.2),
                    ],
                    text: "bad"
                ),
            ])
        )

        XCTAssertThrowsError(try OCRWorkerResultProjection.project(
            envelope,
            imageSize: CGSize(width: 1_000, height: 1_000)
        )) {
            XCTAssertEqual($0 as? OCRWorkerProtocolError, .invalidPolygon)
        }
    }
}
