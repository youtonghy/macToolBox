import CoreGraphics
import XCTest
@testable import ToolBox

final class CaptureGeometryTests: XCTestCase {
    func testScreenCapturePermissionMapsInjectedPreflightToState() {
        let granted = ScreenCapturePermission(preflight: { true })
        let denied = ScreenCapturePermission(preflight: { false })

        XCTAssertEqual(granted.state, .granted)
        XCTAssertEqual(denied.state, .denied)
    }

    func testScreenCapturePermissionDelegatesRequestAndSettings() {
        var requestCount = 0
        var settingsCount = 0
        let permission = ScreenCapturePermission(
            request: {
                requestCount += 1
                return true
            },
            openSettings: {
                settingsCount += 1
            }
        )

        XCTAssertTrue(permission.requestAccess())
        permission.openSettings()

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(settingsCount, 1)
    }

    func testSelectionAcrossMixedScaleDisplaysProducesPixelFragments() throws {
        let displays = [
            DisplayCaptureGeometry(
                displayID: 1,
                globalFramePoints: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                pixelSize: CGSize(width: 2_000, height: 1_600)
            ),
            DisplayCaptureGeometry(
                displayID: 2,
                globalFramePoints: CGRect(x: 1_000, y: 0, width: 800, height: 600),
                pixelSize: CGSize(width: 800, height: 600)
            ),
        ]

        let fragments = try CaptureGeometry.fragments(
            selection: CGRect(x: 900, y: 100, width: 300, height: 200),
            displays: displays
        )

        XCTAssertEqual(fragments.map(\.displayID), [1, 2])
        XCTAssertEqual(fragments[0].sourcePixels, CGRect(x: 1_800, y: 200, width: 200, height: 400))
        XCTAssertEqual(fragments[1].sourcePixels, CGRect(x: 0, y: 100, width: 200, height: 200))
    }

    func testSelectionOnNegativeXDisplayUsesLocalPixelCoordinates() throws {
        let fragments = try CaptureGeometry.fragments(
            selection: CGRect(x: -800, y: 100, width: 300, height: 200),
            displays: [
                DisplayCaptureGeometry(
                    displayID: 4,
                    globalFramePoints: CGRect(x: -1_000, y: 0, width: 1_000, height: 800),
                    pixelSize: CGSize(width: 2_000, height: 1_600)
                ),
            ]
        )

        XCTAssertEqual(fragments.count, 1)
        XCTAssertEqual(fragments[0].displayID, 4)
        XCTAssertEqual(fragments[0].sourcePixels, CGRect(x: 400, y: 200, width: 600, height: 400))
    }

    func testSelectionOnDisplayAbovePrimaryUsesGlobalYCoordinates() throws {
        let fragments = try CaptureGeometry.fragments(
            selection: CGRect(x: 100, y: 850, width: 200, height: 100),
            displays: [
                DisplayCaptureGeometry(
                    displayID: 7,
                    globalFramePoints: CGRect(x: 0, y: 800, width: 1_000, height: 600),
                    pixelSize: CGSize(width: 1_000, height: 1_200)
                ),
            ]
        )

        XCTAssertEqual(fragments[0].sourcePixels, CGRect(x: 100, y: 100, width: 200, height: 200))
    }

    func testEmptySelectionIsInvalid() {
        XCTAssertThrowsError(try CaptureGeometry.fragments(
            selection: CGRect(x: 0, y: 0, width: 0, height: 20),
            displays: [validDisplay]
        )) {
            XCTAssertEqual($0 as? CaptureGeometryError, .invalidSelection)
        }
    }

    func testNonFiniteSelectionIsInvalid() {
        XCTAssertThrowsError(try CaptureGeometry.fragments(
            selection: CGRect(x: CGFloat.infinity, y: 0, width: 20, height: 20),
            displays: [validDisplay]
        )) {
            XCTAssertEqual($0 as? CaptureGeometryError, .invalidSelection)
        }
    }

    func testInvalidDisplayGeometryIsRejected() {
        let display = DisplayCaptureGeometry(
            displayID: 8,
            globalFramePoints: CGRect(x: 0, y: 0, width: 100, height: 100),
            pixelSize: CGSize(width: 0, height: 100)
        )

        XCTAssertThrowsError(try CaptureGeometry.fragments(
            selection: CGRect(x: 0, y: 0, width: 20, height: 20),
            displays: [display]
        )) {
            XCTAssertEqual($0 as? CaptureGeometryError, .invalidDisplayGeometry(8))
        }
    }

    func testSelectionWithoutIntersectingDisplaysIsRejected() {
        XCTAssertThrowsError(try CaptureGeometry.fragments(
            selection: CGRect(x: 500, y: 500, width: 20, height: 20),
            displays: [validDisplay]
        )) {
            XCTAssertEqual($0 as? CaptureGeometryError, .noIntersectingDisplays)
        }
    }

    func testFractionalPointSelectionRoundsPixelBoundsOutward() throws {
        let fragments = try CaptureGeometry.fragments(
            selection: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            displays: [
                DisplayCaptureGeometry(
                    displayID: 9,
                    globalFramePoints: CGRect(x: 0, y: 0, width: 100, height: 100),
                    pixelSize: CGSize(width: 200, height: 200)
                ),
            ]
        )

        XCTAssertEqual(fragments[0].sourcePixels, CGRect(x: 0, y: 0, width: 2, height: 2))
    }

    func testFragmentsUseStableGlobalIntersectionOrder() throws {
        let displays = [
            DisplayCaptureGeometry(
                displayID: 30,
                globalFramePoints: CGRect(x: 100, y: 0, width: 100, height: 100),
                pixelSize: CGSize(width: 100, height: 100)
            ),
            DisplayCaptureGeometry(
                displayID: 10,
                globalFramePoints: CGRect(x: 0, y: 100, width: 100, height: 100),
                pixelSize: CGSize(width: 100, height: 100)
            ),
            DisplayCaptureGeometry(
                displayID: 20,
                globalFramePoints: CGRect(x: 0, y: 0, width: 100, height: 100),
                pixelSize: CGSize(width: 100, height: 100)
            ),
        ]

        let fragments = try CaptureGeometry.fragments(
            selection: CGRect(x: 0, y: 0, width: 200, height: 200),
            displays: displays
        )

        XCTAssertEqual(fragments.map(\.displayID), [20, 10, 30])
    }

    private var validDisplay: DisplayCaptureGeometry {
        DisplayCaptureGeometry(
            displayID: 1,
            globalFramePoints: CGRect(x: 0, y: 0, width: 100, height: 100),
            pixelSize: CGSize(width: 100, height: 100)
        )
    }
}
