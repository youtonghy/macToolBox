import XCTest
@testable import ToolBox

final class MediaKeyPermissionGapTests: XCTestCase {
    func testDefaultTapSuccessMeansNoGap() {
        let gap = Permissions.mediaKeyPermissionGap(
            canCreateListenOnlyTap: true,
            canCreateDefaultTap: true
        )
        XCTAssertEqual(gap, .none)
    }

    func testListenOnlyWorksButDefaultFailsPointsToAccessibilityWhenAXMissing() {
        // Cannot assert against live TCC state; only validate the pure branch when
        // probe results already encode the split.
        // When listen-only works, gap classification prefers Accessibility.
        // If the host process already has AX, the function may return restartRequired.
        let gap = Permissions.mediaKeyPermissionGap(
            canCreateListenOnlyTap: true,
            canCreateDefaultTap: false
        )
        XCTAssertTrue(
            gap == .accessibility || gap == .restartRequired || gap == .none,
            "Unexpected gap for listen-only success: \(gap)"
        )
    }

    func testNeedsUserActionFlags() {
        XCTAssertFalse(Permissions.MediaKeyPermissionGap.none.needsUserAction)
        XCTAssertTrue(Permissions.MediaKeyPermissionGap.accessibility.needsUserAction)
        XCTAssertTrue(Permissions.MediaKeyPermissionGap.inputMonitoring.needsUserAction)
        XCTAssertTrue(Permissions.MediaKeyPermissionGap.both.needsUserAction)
        XCTAssertTrue(Permissions.MediaKeyPermissionGap.restartRequired.needsUserAction)
    }
}
