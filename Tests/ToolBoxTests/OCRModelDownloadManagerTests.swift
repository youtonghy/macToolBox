import CryptoKit
import XCTest
@testable import ToolBoxCore

final class OCRModelDownloadManagerTests: XCTestCase {
    func testRequiresConsentThenDownloadsEveryFileAndPublishes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let det = Data("detector".utf8)
        let rec = Data("recognizer".utf8)
        let files = [
            file("det/inference.onnx", data: det),
            file("rec/inference.onnx", data: rec),
        ]
        let manifest = try makeOCRManifest(files: files)
        let downloader = FakeOCRFileDownloader(payloads: [files[0].url: det, files[1].url: rec])
        let store = OCRModelStore(rootDirectory: root)
        let manager = OCRModelDownloadManager(store: store, downloader: downloader)

        await XCTAssertThrowsErrorAsync(try await manager.install(manifest: manifest, userConsented: false)) {
            XCTAssertEqual($0 as? OCRModelDownloadError, .consentRequired)
        }
        let callsBeforeConsent = await downloader.callCount
        XCTAssertEqual(callsBeforeConsent, 0)

        let directory = try await manager.install(manifest: manifest, userConsented: true)

        let callsAfterInstall = await downloader.callCount
        XCTAssertEqual(callsAfterInstall, 2)
        XCTAssertEqual(try store.state(for: manifest), .ready)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("det/inference.onnx")), det)
    }

    func testBadDownloadCleansStagingAndDoesNotPublish() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = Data("expected".utf8)
        let manifest = try makeOCRManifest(files: [file("det/inference.onnx", data: expected)])
        let downloader = FakeOCRFileDownloader(payloads: [manifest.files[0].url: Data("tampered".utf8)])
        let store = OCRModelStore(rootDirectory: root)
        let manager = OCRModelDownloadManager(store: store, downloader: downloader)

        await XCTAssertThrowsErrorAsync(try await manager.install(manifest: manifest, userConsented: true))

        XCTAssertEqual(try store.state(for: manifest), .notInstalled)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: root.path)).isEmpty)
    }

    func testReinstallReplacesCorruptModel() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = Data("verified".utf8)
        let manifest = try makeOCRManifest(files: [file("det/inference.onnx", data: expected)])
        let downloader = FakeOCRFileDownloader(payloads: [manifest.files[0].url: expected])
        let store = OCRModelStore(rootDirectory: root)
        let manager = OCRModelDownloadManager(store: store, downloader: downloader)
        let directory = try await manager.install(manifest: manifest, userConsented: true)
        try Data("tampered".utf8).write(
            to: directory.appendingPathComponent("det/inference.onnx")
        )
        XCTAssertEqual(try store.state(for: manifest), .corrupt)

        let repaired = try await manager.install(manifest: manifest, userConsented: true)

        XCTAssertEqual(try store.state(for: manifest), .ready)
        XCTAssertEqual(
            try Data(contentsOf: repaired.appendingPathComponent("det/inference.onnx")),
            expected
        )
        let calls = await downloader.callCount
        XCTAssertEqual(calls, 2)
    }

    private func file(_ path: String, data: Data) -> OCRModelFileManifest {
        OCRModelFileManifest(
            relativePath: path,
            url: immutableURL(path),
            byteCount: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-model-download-\(UUID().uuidString)", isDirectory: true)
    }
}

private actor FakeOCRFileDownloader: OCRModelFileDownloading {
    let payloads: [URL: Data]
    private(set) var callCount = 0

    init(payloads: [URL: Data]) { self.payloads = payloads }

    func download(_ url: URL) async throws -> URL {
        callCount += 1
        guard let data = payloads[url] else { throw URLError(.fileDoesNotExist) }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-fake-download-\(UUID().uuidString)")
        try data.write(to: output)
        return output
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
