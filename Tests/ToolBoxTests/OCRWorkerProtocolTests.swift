import Foundation
import XCTest
@testable import ToolBoxCore

final class OCRWorkerProtocolTests: XCTestCase {
    func testRequestAndCancelEnvelopesRoundTripWithRelativeInput() throws {
        let request = try OCRWorkerRequestEnvelope(
            taskID: "task-1",
            pipeline: .paddleOCRVL,
            variantID: "v1.6",
            imagePath: "input.png",
            modelDirectory: "/tmp/models"
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(OCRWorkerRequestEnvelope.self, from: data)
        XCTAssertEqual(decoded, request)

        let cancel = try OCRWorkerCancelEnvelope(taskID: "task-1")
        XCTAssertEqual(cancel.type, "cancel")
    }

    func testRejectsUnsafeWorkerPathsAndInvalidConfidence() throws {
        XCTAssertThrowsError(try OCRWorkerRequestEnvelope(
            taskID: "task-1",
            pipeline: .paddleOCRVL,
            variantID: "v1.6",
            imagePath: "../input.png",
            modelDirectory: "/tmp/models"
        )) {
            XCTAssertEqual($0 as? OCRWorkerProtocolError, .invalidPath)
        }

        let invalid = Data(#"{"schemaVersion":1,"taskID":"task-1","pipeline":"ppStructureV3","variantID":"default","result":{"kind":"structured","blocks":[{"kind":"title","polygon":[[0,0],[1,0],[1,1],[0,1]],"confidence":2}]}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(OCRWorkerResultEnvelope.self, from: invalid)) {
            XCTAssertEqual($0 as? OCRWorkerProtocolError, .invalidResult)
        }
    }

    func testDecodesStructuredResultEnvelopeWithLayoutBlocks() throws {
        let data = Data(#"""
        {
          "schemaVersion": 1,
          "taskID": "task-1",
          "pipeline": "ppStructureV3",
          "variantID": "default",
          "result": {
            "kind": "structured",
            "blocks": [
              {
                "id": "title-1",
                "kind": "title",
                "polygon": [[0.1, 0.1], [0.9, 0.1], [0.9, 0.2], [0.1, 0.2]],
                "text": "Report"
              }
            ]
          }
        }
        """#.utf8)

        let envelope = try JSONDecoder().decode(OCRWorkerResultEnvelope.self, from: data)

        XCTAssertEqual(envelope.schemaVersion, 1)
        XCTAssertEqual(envelope.taskID, "task-1")
        XCTAssertEqual(envelope.pipeline, .ppStructureV3)
        guard case let .structured(blocks) = envelope.result else {
            return XCTFail("expected structured result")
        }
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, "title")
        XCTAssertEqual(blocks[0].text, "Report")
    }

    func testRejectsUnknownSchemaAndPipeline() throws {
        let unknownSchema = Data(#"{"schemaVersion":2,"taskID":"x","pipeline":"ppStructureV3","variantID":"default","result":{"kind":"structured","blocks":[]}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(OCRWorkerResultEnvelope.self, from: unknownSchema)) {
            XCTAssertEqual($0 as? OCRWorkerProtocolError, .unsupportedSchema(2))
        }

        let unknownPipeline = Data(#"{"schemaVersion":1,"taskID":"x","pipeline":"future","variantID":"default","result":{"kind":"structured","blocks":[]}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(OCRWorkerResultEnvelope.self, from: unknownPipeline)) {
            XCTAssertEqual($0 as? OCRWorkerProtocolError, .unsupportedPipeline("future"))
        }
    }

    func testRejectsOversizedMarkdownBeforeProjection() throws {
        let markdown = String(repeating: "x", count: 16 * 1024 * 1024 + 1)
        let envelope = OCRWorkerResultEnvelope(
            taskID: "task-1",
            pipeline: .paddleOCRVL,
            variantID: "v1.6",
            result: .document(
                markdown: markdown,
                blocks: []
            )
        )

        XCTAssertThrowsError(try OCRWorkerResultProjection.project(
            envelope,
            imageSize: CGSize(width: 1_000, height: 1_000)
        )) {
            XCTAssertEqual($0 as? OCRWorkerProtocolError, .resultTooLarge)
        }
    }
}
