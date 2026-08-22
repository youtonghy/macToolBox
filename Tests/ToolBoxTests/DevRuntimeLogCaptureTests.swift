import Foundation
import XCTest
@testable import ToolBoxCore

final class DevRuntimeLogCapturePolicyTests: XCTestCase {
    func testOnlyDEVMarketingVersionsEnableRuntimeCapture() {
        XCTAssertTrue(DevRuntimeLogCapturePolicy.isEnabled(marketingVersion: "DEV0.0.0"))
        XCTAssertTrue(DevRuntimeLogCapturePolicy.isEnabled(marketingVersion: "DEV-local"))
        XCTAssertFalse(DevRuntimeLogCapturePolicy.isEnabled(marketingVersion: "1.2.3"))
        XCTAssertFalse(DevRuntimeLogCapturePolicy.isEnabled(marketingVersion: "dev0.0.0"))
        XCTAssertFalse(DevRuntimeLogCapturePolicy.isEnabled(marketingVersion: nil))
    }

    func testLogStreamArgumentsCaptureAllDebugEntriesForTheCurrentProcess() {
        XCTAssertEqual(
            DevRuntimeLogCapturePolicy.logStreamArguments(processID: 42),
            [
                "stream",
                "--process", "42",
                "--level", "debug",
                "--style", "compact",
                "--color", "none",
            ]
        )
    }

    func testSessionFileNameContainsSortableTimestampAndProcessID() {
        let date = ISO8601DateFormatter().date(from: "2026-08-01T01:15:06Z")!

        XCTAssertEqual(
            DevRuntimeLogCapturePolicy.sessionFileName(
                date: date,
                processID: 321,
                timeZone: TimeZone(secondsFromGMT: 0)!
            ),
            "ToolBox-20260801-011506-pid321.log"
        )
    }

    func testPruningKeepsNineExistingSessionsBeforeCreatingTheNextOne() {
        let files = (1 ... 12).map {
            URL(fileURLWithPath: String(format: "/logs/ToolBox-20260801-1200%02d-pid1.log", $0))
        }
        let unrelated = URL(fileURLWithPath: "/logs/notes.txt")

        XCTAssertEqual(
            DevRuntimeLogCapturePolicy.filesToRemoveBeforeNewSession(
                from: files + [unrelated],
                maximumRetainedSessions: 10
            ).map(\.lastPathComponent),
            [
                "ToolBox-20260801-120001-pid1.log",
                "ToolBox-20260801-120002-pid1.log",
                "ToolBox-20260801-120003-pid1.log",
            ]
        )
    }
}
