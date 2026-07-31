import CryptoKit
import XCTest
@testable import ToolBox

final class OCRModelStoreTests: XCTestCase {
    func testPublishesVerifiedStagingAtomicallyAndReopensReadyModel() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("verified model".utf8)
        let manifest = try makeOCRManifest(files: [
            OCRModelFileManifest(
                relativePath: "det/inference.onnx",
                url: immutableURL("det/inference.onnx"),
                byteCount: Int64(data.count),
                sha256: SHA256.hash(data: data).hexString
            ),
        ])
        let store = OCRModelStore(rootDirectory: root)
        let staging = try store.makeStagingDirectory(for: manifest)
        let file = staging.appendingPathComponent("det/inference.onnx")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)

        let installed = try store.publish(manifest: manifest, stagingDirectory: staging)

        XCTAssertEqual(try store.state(for: manifest), .ready)
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("det/inference.onnx")), data)
        XCTAssertEqual(FileManager.default.fileExists(atPath: staging.path), false)
    }

    func testHashFailureDoesNotPublishAndLeaseBlocksDeletion() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("good".utf8)
        let manifest = try makeOCRManifest(files: [
            OCRModelFileManifest(
                relativePath: "rec/inference.onnx",
                url: immutableURL("rec/inference.onnx"),
                byteCount: Int64(data.count),
                sha256: SHA256.hash(data: data).hexString
            ),
        ])
        let store = OCRModelStore(rootDirectory: root)
        let badStaging = try store.makeStagingDirectory(for: manifest)
        let badFile = badStaging.appendingPathComponent("rec/inference.onnx")
        try FileManager.default.createDirectory(at: badFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("evil!".utf8).write(to: badFile)
        XCTAssertThrowsError(try store.publish(manifest: manifest, stagingDirectory: badStaging)) {
            XCTAssertEqual($0 as? OCRModelStoreError, .lengthMismatch)
        }
        XCTAssertEqual(try store.state(for: manifest), .notInstalled)

        let goodStaging = try store.makeStagingDirectory(for: manifest)
        let goodFile = goodStaging.appendingPathComponent("rec/inference.onnx")
        try FileManager.default.createDirectory(at: goodFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: goodFile)
        _ = try store.publish(manifest: manifest, stagingDirectory: goodStaging)
        var lease: OCRModelLease? = try store.acquireLease(for: manifest)
        XCTAssertThrowsError(try store.delete(manifest: manifest)) {
            XCTAssertEqual($0 as? OCRModelStoreError, .modelInUse)
        }
        XCTAssertNotNil(lease?.directory)
        lease = nil
        XCTAssertNoThrow(try store.delete(manifest: manifest))
        XCTAssertEqual(try store.state(for: manifest), .notInstalled)
    }

    func testRemovesHiddenAbandonedStagingDirectories() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OCRModelStore(rootDirectory: root)
        let staging = try store.makeStagingDirectory(for: makeOCRManifest())

        try store.removeAbandonedStagingDirectories()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-model-store-\(UUID().uuidString)", isDirectory: true)
    }
}

private extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
