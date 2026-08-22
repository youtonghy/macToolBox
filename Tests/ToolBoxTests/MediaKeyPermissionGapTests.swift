import XCTest
@testable import ToolBoxCore

final class MediaKeyPermissionGapTests: XCTestCase {
    func testDefaultTapSuccessMeansNoGap() {
        XCTAssertEqual(
            gap(listenOnly: false, defaultTap: true, inputMonitoring: false, accessibility: false),
            .none
        )
    }

    func testListenOnlySuccessOverridesStaleInputMonitoringPreflight() {
        XCTAssertEqual(
            gap(listenOnly: true, defaultTap: false, inputMonitoring: false, accessibility: false),
            .accessibility
        )
        XCTAssertEqual(
            gap(listenOnly: true, defaultTap: false, inputMonitoring: false, accessibility: true),
            .restartRequired
        )
    }

    func testFailedTapTruthTable() {
        XCTAssertEqual(
            gap(listenOnly: false, defaultTap: false, inputMonitoring: false, accessibility: false),
            .both
        )
        XCTAssertEqual(
            gap(listenOnly: false, defaultTap: false, inputMonitoring: false, accessibility: true),
            .inputMonitoring
        )
        XCTAssertEqual(
            gap(listenOnly: false, defaultTap: false, inputMonitoring: true, accessibility: false),
            .accessibility
        )
        XCTAssertEqual(
            gap(listenOnly: false, defaultTap: false, inputMonitoring: true, accessibility: true),
            .restartRequired
        )
    }

    func testNeedsUserActionFlags() {
        XCTAssertFalse(Permissions.MediaKeyPermissionGap.none.needsUserAction)
        XCTAssertTrue(Permissions.MediaKeyPermissionGap.accessibility.needsUserAction)
        XCTAssertTrue(Permissions.MediaKeyPermissionGap.inputMonitoring.needsUserAction)
        XCTAssertTrue(Permissions.MediaKeyPermissionGap.both.needsUserAction)
        XCTAssertTrue(Permissions.MediaKeyPermissionGap.restartRequired.needsUserAction)
    }

    private func gap(
        listenOnly: Bool?,
        defaultTap: Bool?,
        inputMonitoring: Bool,
        accessibility: Bool
    ) -> Permissions.MediaKeyPermissionGap {
        Permissions.mediaKeyPermissionGap(
            canCreateListenOnlyTap: listenOnly,
            canCreateDefaultTap: defaultTap,
            inputMonitoringTrusted: inputMonitoring,
            accessibilityTrusted: accessibility
        )
    }
}
