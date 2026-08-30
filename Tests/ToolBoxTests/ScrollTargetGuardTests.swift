import CoreGraphics
import XCTest
@testable import ToolBoxCore

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

    func testRejectsTargetThatLostFrontmostOrTopologySignatureChange() throws {
        let target = snapshot()
        let guarder = ScrollTargetGuard()
        // User switched apps: posted scroll events would hit another window.
        XCTAssertThrowsError(try guarder.validate(target, against: observation(isFrontmost: false))) {
            XCTAssertEqual($0 as? ScrollCaptureTargetError, .targetChanged)
        }
        // Another window of the same app now covers the scroll location.
        XCTAssertThrowsError(
            try guarder.validate(target, against: observation(isTargetTopmostAtScrollLocation: false))
        ) {
            XCTAssertEqual($0 as? ScrollCaptureTargetError, .targetChanged)
        }
        // Same display ID, but the layout itself changed (re-scale, hot-plug).
        XCTAssertThrowsError(try guarder.validate(target, against: observation(topologySignature: 999))) {
            XCTAssertEqual($0 as? ScrollCaptureTargetError, .displayChanged)
        }
    }

    func testTargetTopmostDetectsSameAppWindowCoveringScrollLocation() {
        let converter = QuartzWindowCoordinateConverter(
            primaryDisplayHeight: 900,
            screens: [.init(displayID: 1, appKitFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900))]
        )
        let scrollLocation = CGPoint(x: 400, y: 450)

        // Quartz frames are top-left origin: appKit (0,0,1440,900) → quartz (0,0,1440,900)
        // with primary height 900; an appKit rect (0,400,1440,500) maps to quartz y 0.
        func window(id: UInt32, pid: Int32, quartzRect: CGRect) -> [CFString: Any] {
            [
                kCGWindowNumber: NSNumber(value: id),
                kCGWindowOwnerPID: NSNumber(value: pid),
                kCGWindowBounds: NSDictionary(dictionary: [
                    "X": quartzRect.minX, "Y": quartzRect.minY,
                    "Width": quartzRect.width, "Height": quartzRect.height,
                ]),
            ]
        }
        let target = window(id: 7, pid: 42, quartzRect: CGRect(x: 0, y: 0, width: 1_440, height: 900))

        // Target alone.
        XCTAssertTrue(SystemScrollTargetObserver.isTargetTopmost(
            windows: [target], targetWindowID: 7, ownerPID: 42,
            scrollLocation: scrollLocation, converter: converter
        ))

        // A sibling window of the SAME app, above the target, covering the point.
        let coveringSibling = window(id: 8, pid: 42, quartzRect: CGRect(x: 300, y: 100, width: 400, height: 400))
        XCTAssertFalse(SystemScrollTargetObserver.isTargetTopmost(
            windows: [coveringSibling, target], targetWindowID: 7, ownerPID: 42,
            scrollLocation: scrollLocation, converter: converter
        ))

        // Same-app sibling above but NOT covering the point: still fine.
        let asideSibling = window(id: 9, pid: 42, quartzRect: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(SystemScrollTargetObserver.isTargetTopmost(
            windows: [asideSibling, target], targetWindowID: 7, ownerPID: 42,
            scrollLocation: scrollLocation, converter: converter
        ))

        // Other apps' windows above are the frontmost check's concern, not ours.
        let otherApp = window(id: 10, pid: 99, quartzRect: CGRect(x: 0, y: 0, width: 1_440, height: 900))
        XCTAssertTrue(SystemScrollTargetObserver.isTargetTopmost(
            windows: [otherApp, target], targetWindowID: 7, ownerPID: 42,
            scrollLocation: scrollLocation, converter: converter
        ))

        // Target gone from the list entirely.
        XCTAssertFalse(SystemScrollTargetObserver.isTargetTopmost(
            windows: [coveringSibling], targetWindowID: 7, ownerPID: 42,
            scrollLocation: scrollLocation, converter: converter
        ))
    }

    func testTopologySignatureIsOrderIndependentAndLayoutSensitive() {
        let displays = [
            DisplayTopologyEntry(
                displayID: 1,
                frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                backingScaleFactor: 2
            ),
            DisplayTopologyEntry(
                displayID: 2,
                frame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080),
                backingScaleFactor: 1
            ),
        ]
        let baseline = ScrollTopologySignature.make(displays)

        // Entry order must not matter.
        XCTAssertEqual(baseline, ScrollTopologySignature.make(displays.reversed()))

        // Scaling, moving, removing, or adding a display must change the hash.
        XCTAssertNotEqual(
            baseline,
            ScrollTopologySignature.make(displays.map { entry in
                DisplayTopologyEntry(
                    displayID: entry.displayID,
                    frame: entry.frame,
                    backingScaleFactor: entry.backingScaleFactor == 2 ? 1 : entry.backingScaleFactor
                )
            })
        )
        XCTAssertNotEqual(
            baseline,
            ScrollTopologySignature.make(
                displays.map { entry in
                    DisplayTopologyEntry(
                        displayID: entry.displayID,
                        frame: entry.frame.offsetBy(dx: 10, dy: 0),
                        backingScaleFactor: entry.backingScaleFactor
                    )
                }
            )
        )
        XCTAssertNotEqual(baseline, ScrollTopologySignature.make(Array(displays.dropLast())))
        XCTAssertNotEqual(
            baseline,
            ScrollTopologySignature.make(displays + [
                DisplayTopologyEntry(
                    displayID: 3,
                    frame: CGRect(x: -640, y: 0, width: 640, height: 480),
                    backingScaleFactor: 1
                )
            ])
        )
    }

    private func snapshot() -> ScrollCaptureTargetSnapshot {
        ScrollCaptureTargetSnapshot(
            ownerPID: 42,
            windowID: 7,
            displayID: 1,
            topologyGeneration: 9,
            topologySignature: 100,
            roiGlobal: CGRect(x: 20, y: 30, width: 100, height: 80),
            windowGlobalFrame: CGRect(x: 0, y: 0, width: 400, height: 500)
        )
    }

    private func observation(
        isProcessRunning: Bool = true,
        isFrontmost: Bool = true,
        isTargetTopmostAtScrollLocation: Bool = true,
        windowID: CGWindowID = 7,
        displayID: CGDirectDisplayID = 1,
        topologySignature: UInt64 = 100,
        windowFrame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 500)
    ) -> ScrollTargetObservation {
        ScrollTargetObservation(
            isProcessRunning: isProcessRunning,
            isFrontmost: isFrontmost,
            isTargetTopmostAtScrollLocation: isTargetTopmostAtScrollLocation,
            ownerPID: 42,
            windowID: windowID,
            displayID: displayID,
            topologySignature: topologySignature,
            windowGlobalFrame: windowFrame
        )
    }
}
