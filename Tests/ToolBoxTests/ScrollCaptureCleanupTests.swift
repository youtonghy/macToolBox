import Foundation
import XCTest
@testable import ToolBox

final class ScrollCaptureCleanupTests: XCTestCase {
    func testRemovesOnlyRecognizedStaleSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scroll-cleanup-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stale = root.appendingPathComponent("session-\(UUID().uuidString)", isDirectory: true)
        let recent = root.appendingPathComponent("session-\(UUID().uuidString)", isDirectory: true)
        let unrelated = root.appendingPathComponent("keep-me", isDirectory: true)
        for url in [stale, recent, unrelated] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        let now = Date(timeIntervalSince1970: 100_000)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-90_000)], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-100)], ofItemAtPath: recent.path)

        try ScrollCaptureCleanup.removeStaleSessions(rootDirectory: root, now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
