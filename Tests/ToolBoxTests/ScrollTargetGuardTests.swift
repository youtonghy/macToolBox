import CoreGraphics
import XCTest
@testable import ToolBox

final class ScrollTargetGuardTests: XCTestCase {
    func testAcceptsMatchingObservationAndRejectsIdentityOrGeometryChange() throws {
        let target = snapshot()
        let guarder = ScrollTargetGuard()
        XCTAssertNoThrow(try guarder.validate(target, against: observation()))

        XCTAssertThrowsError(try guarder.validate(target, against: observation(windowID: 8))) {
            XCTAssertEqual($0 as? ScrollCaptureTargetError, .targetChanged)
        }
        XCTAssertThrowsError(
            try guarder.validate(
                target,
                against: observation(windowFrame: CGRect(x: 0, y: 0, width: 390, height: 500))
            )
        ) { XCTAssertEqual($0 as? ScrollCaptureTargetError, .targetChanged) }
    }

    func testRejectsExitedProcessDisplayChangeAndClippedROI() throws {
        let target = snapshot()
        let guarder = ScrollTargetGuard()
        XCTAssertThrowsError(try guarder.validate(target, against: observation(isProcessRunning: false))) {
            XCTAssertEqual($0 as? ScrollCaptureTargetError, .targetUnavailable)
        }
        XCTAssertThrowsError(try guarder.validate(target, against: observation(displayID: 2))) {
            XCTAssertEqual($0 as? ScrollCaptureTargetError, .displayChanged)
        }
        XCTAssertThrowsError(
            try guarder.validate(
                target,
                against: observation(windowFrame: CGRect(x: 0, y: 0, width: 50, height: 50))
            )
        ) { XCTAssertEqual($0 as? ScrollCaptureTargetError, .roiOutsideWindow) }
    }

    private func snapshot() -> ScrollCaptureTargetSnapshot {
        ScrollCaptureTargetSnapshot(
            ownerPID: 42,
            windowID: 7,
            displayID: 1,
            topologyGeneration: 9,
            roiGlobal: CGRect(x: 20, y: 30, width: 100, height: 80),
            windowGlobalFrame: CGRect(x: 0, y: 0, width: 400, height: 500)
        )
    }

    private func observation(
        isProcessRunning: Bool = true,
        windowID: CGWindowID = 7,
        displayID: CGDirectDisplayID = 1,
        windowFrame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 500)
    ) -> ScrollTargetObservation {
        ScrollTargetObservation(
            isProcessRunning: isProcessRunning,
            ownerPID: 42,
            windowID: windowID,
            displayID: displayID,
            topologyGeneration: 9,
            windowGlobalFrame: windowFrame
        )
    }
}
