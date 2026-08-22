import CoreGraphics
import Foundation
import XCTest
@testable import ToolBoxCore

final class OCRWorkerClientTests: XCTestCase {
    func testRunsBundledProtocolExecutableAndProjectsDocumentResult() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-worker-client-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = root.appendingPathComponent("worker.sh")
        let contents = """
        #!/bin/sh
        test "$HF_HUB_OFFLINE" = "1" || exit 41
        test "$TRANSFORMERS_OFFLINE" = "1" || exit 42
        test "$PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK" = "True" || exit 43
        test -n "$PADDLE_PDX_CACHE_HOME" || exit 44
        read request
        task=$(printf '%s' "$request" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["taskID"])')
        printf '{\"type\":\"result\",\"schemaVersion\":1,\"taskID\":\"%s\",\"pipeline\":\"paddleOCRVL\",\"variantID\":\"v1.6\",\"result\":{\"kind\":\"document\",\"markdown\":\"# Result\",\"blocks\":[]}}\\n' "$task"
        """
        try Data(contents.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let worker = try OCRWorkerRunning(
            executable: OCRWorkerExecutable(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [script.path]
            ),
            timeout: .seconds(5)
        )
        let image = try XCTUnwrap(makeImage())
        let source = CGImageScreenshotSource(image: image)
        let modelDirectory = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let result = try await worker.run(
            source: source,
            selection: OCRModelSelection(pipeline: .paddleOCRVL, variantID: "v1.6"),
            modelDirectory: modelDirectory
        )

        guard case let .document(document) = result else {
            return XCTFail("expected document result")
        }
        XCTAssertEqual(document.markdown, "# Result")
    }

    private func makeImage() -> CGImage? {
        let context = CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return context?.makeImage()
    }
}
