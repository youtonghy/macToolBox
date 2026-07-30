import CoreGraphics
import XCTest
@testable import ToolBox

final class FocusTargetResolverTests: XCTestCase {
    private let horizontalScreens = [
        FocusScreenGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1_000, height: 1_080)),
        FocusScreenGeometry(id: 2, frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 1_080)),
    ]

    func testAXWindowUsesTopLeftCoordinatesToSelectRightDisplay() {
        let snapshot = FocusSystemSnapshot(
            frontmostApplicationPID: 42,
            accessibilityTrusted: true,
            axFocusedWindowFrame: CGRect(x: 1_200, y: 100, width: 600, height: 700),
            mouseLocation: CGPoint(x: 100, y: 100)
        )

        let result = FocusTargetResolver.resolve(
            screens: horizontalScreens,
            snapshot: snapshot,
            ownProcessID: 99,
            lastExternalDisplayID: 1
        )

        XCTAssertEqual(result, 2)
    }

    func testAXCoordinateConversionSupportsDisplaysAboveAndBelowPrimary() {
        let screens = [
            FocusScreenGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1_000, height: 1_080)),
            FocusScreenGeometry(id: 2, frame: CGRect(x: 0, y: 1_080, width: 1_000, height: 900)),
            FocusScreenGeometry(id: 3, frame: CGRect(x: 0, y: -900, width: 1_000, height: 900)),
        ]

        let above = FocusTargetResolver.resolve(
            screens: screens,
            snapshot: FocusSystemSnapshot(
                frontmostApplicationPID: 42,
                accessibilityTrusted: true,
                axFocusedWindowFrame: CGRect(x: 100, y: -620, width: 600, height: 500),
                mouseLocation: nil
            ),
            ownProcessID: 99,
            lastExternalDisplayID: nil
        )
        let below = FocusTargetResolver.resolve(
            screens: screens,
            snapshot: FocusSystemSnapshot(
                frontmostApplicationPID: 42,
                accessibilityTrusted: true,
                axFocusedWindowFrame: CGRect(x: 100, y: 1_380, width: 600, height: 500),
                mouseLocation: nil
            ),
            ownProcessID: 99,
            lastExternalDisplayID: nil
        )

        XCTAssertEqual(above, 2)
        XCTAssertEqual(below, 3)
    }

    func testCrossDisplayWindowUsesLargestIntersection() {
        let result = FocusTargetResolver.resolve(
            screens: horizontalScreens,
            snapshot: FocusSystemSnapshot(
                frontmostApplicationPID: 42,
                accessibilityTrusted: true,
                axFocusedWindowFrame: CGRect(x: 800, y: 380, width: 700, height: 600),
                mouseLocation: nil
            ),
            ownProcessID: 99,
            lastExternalDisplayID: nil
        )

        XCTAssertEqual(result, 2)
    }

    func testEqualIntersectionUsesCenterThenLastThenStableID() {
        let adjacent = FocusTargetResolver.resolve(
            screens: horizontalScreens,
            snapshot: FocusSystemSnapshot(
                frontmostApplicationPID: 42,
                accessibilityTrusted: true,
                axFocusedWindowFrame: CGRect(x: 750, y: 380, width: 500, height: 600),
                mouseLocation: nil
            ),
            ownProcessID: 99,
            lastExternalDisplayID: 1
        )
        let screensWithGap = [
            FocusScreenGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 900, height: 1_080)),
            FocusScreenGeometry(id: 2, frame: CGRect(x: 1_100, y: 0, width: 900, height: 1_080)),
        ]
        let lastWins = FocusTargetResolver.resolve(
            screens: screensWithGap,
            snapshot: FocusSystemSnapshot(
                frontmostApplicationPID: 42,
                accessibilityTrusted: true,
                axFocusedWindowFrame: CGRect(x: 800, y: 380, width: 400, height: 600),
                mouseLocation: nil
            ),
            ownProcessID: 99,
            lastExternalDisplayID: 2
        )
        let stableWins = FocusTargetResolver.resolve(
            screens: screensWithGap,
            snapshot: FocusSystemSnapshot(
                frontmostApplicationPID: 42,
                accessibilityTrusted: true,
                axFocusedWindowFrame: CGRect(x: 800, y: 380, width: 400, height: 600),
                mouseLocation: nil
            ),
            ownProcessID: 99,
            lastExternalDisplayID: nil
        )

        XCTAssertEqual(adjacent, 2)
        XCTAssertEqual(lastWins, 2)
        XCTAssertEqual(stableWins, 1)
    }

    func testOwnApplicationPreservesLastExternalDisplayBeforeMouseFallback() {
        let result = FocusTargetResolver.resolve(
            screens: horizontalScreens,
            snapshot: FocusSystemSnapshot(
                frontmostApplicationPID: 99,
                accessibilityTrusted: true,
                axFocusedWindowFrame: CGRect(x: 1_100, y: 100, width: 700, height: 700),
                mouseLocation: CGPoint(x: 1_500, y: 500)
            ),
            ownProcessID: 99,
            lastExternalDisplayID: 1
        )

        XCTAssertEqual(result, 1)
    }

    func testUnavailableOrInvalidAXFallsBackToMouseThenLastThenPrimary() {
        let mouse = FocusTargetResolver.resolve(
            screens: horizontalScreens,
            snapshot: FocusSystemSnapshot(
                frontmostApplicationPID: 42,
                accessibilityTrusted: false,
                axFocusedWindowFrame: CGRect(x: 100, y: 100, width: 500, height: 500),
                mouseLocation: CGPoint(x: 1_500, y: 500)
            ),
            ownProcessID: 99,
            lastExternalDisplayID: 1
        )
        let last = FocusTargetResolver.resolve(
            screens: horizontalScreens,
            snapshot: FocusSystemSnapshot(
                frontmostApplicationPID: 42,
                accessibilityTrusted: true,
                axFocusedWindowFrame: CGRect(x: CGFloat.nan, y: 100, width: 500, height: 500),
                mouseLocation: CGPoint(x: 4_000, y: 4_000)
            ),
            ownProcessID: 99,
            lastExternalDisplayID: 2
        )
        let primary = FocusTargetResolver.resolve(
            screens: horizontalScreens,
            snapshot: FocusSystemSnapshot(
                frontmostApplicationPID: nil,
                accessibilityTrusted: true,
                axFocusedWindowFrame: nil,
                mouseLocation: nil
            ),
            ownProcessID: 99,
            lastExternalDisplayID: 88
        )

        XCTAssertEqual(mouse, 2)
        XCTAssertEqual(last, 2)
        XCTAssertEqual(primary, 1)
    }

    func testZeroAndSingleScreenInputsAreStable() {
        let snapshot = FocusSystemSnapshot(
            frontmostApplicationPID: nil,
            accessibilityTrusted: false,
            axFocusedWindowFrame: nil,
            mouseLocation: nil
        )

        XCTAssertNil(FocusTargetResolver.resolve(
            screens: [],
            snapshot: snapshot,
            ownProcessID: 99,
            lastExternalDisplayID: nil
        ))
        XCTAssertEqual(FocusTargetResolver.resolve(
            screens: [FocusScreenGeometry(id: 7, frame: CGRect(x: 0, y: 0, width: 800, height: 600))],
            snapshot: snapshot,
            ownProcessID: 99,
            lastExternalDisplayID: nil
        ), 7)
    }
}
