import CoreGraphics
import XCTest
@testable import ToolBox

final class ScrollTargetGuardTests: XCTestCase {
    func testQuartzCoordinateConversionUsesStablePrimaryDisplayHeight() {
        let converter = QuartzWindowCoordinateConverter(
            primaryDisplayHeight: 900,
            screens: [
                .init(displayID: 1, appKitFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)),
                .init(displayID: 2, appKitFrame: CGRect(x: 0, y: 900, width: 1_920, height: 1_080)),
                .init(displayID: 3, appKitFrame: CGRect(x: -1_280, y: 0, width: 1_280, height: 720)),
            ]
        )

        let upper = converter.appKitFrame(fromQuartzFrame: CGRect(x: 100, y: -700, width: 300, height: 200))
        let left = converter.appKitFrame(fromQuartzFrame: CGRect(x: -1_000, y: 300, width: 200, height: 100))

        XCTAssertEqual(upper, CGRect(x: 100, y: 1_400, width: 300, height: 200))
        XCTAssertEqual(converter.displayID(containing: upper), 2)
        XCTAssertEqual(left, CGRect(x: -1_000, y: 500, width: 200, height: 100))
        XCTAssertEqual(converter.displayID(containing: left), 3)
    }

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
