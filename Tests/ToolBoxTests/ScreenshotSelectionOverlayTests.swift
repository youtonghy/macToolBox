import CoreGraphics
import XCTest
@testable import ToolBox

@MainActor
final class ScreenshotSelectionOverlayTests: XCTestCase {
    func testCreatesOneFixedPanelPerDisplayAndTransfersKeyCapability() throws {
        let manager = ScreenshotSelectionOverlayManager(activateApplication: false)
        try manager.show(frames: [try frame(id: 1, x: 0), try frame(id: 2, x: 100)], state: .empty)

        XCTAssertEqual(manager.panelCount, 2)
        XCTAssertFalse(manager.panel(for: 1)!.canBecomeMain)
        XCTAssertFalse(manager.panel(for: 1)!.canBecomeKey)
        XCTAssertFalse(manager.panel(for: 2)!.canBecomeKey)

        manager.beginInteraction(on: 2)
        XCTAssertFalse(manager.panel(for: 1)!.canBecomeKey)
        XCTAssertTrue(manager.panel(for: 2)!.canBecomeKey)

        let framesBefore = [manager.panel(for: 1)!.frame, manager.panel(for: 2)!.frame]
        manager.update(state: .empty)
        XCTAssertEqual([manager.panel(for: 1)!.frame, manager.panel(for: 2)!.frame], framesBefore)
        manager.close(cancelled: false)
    }

    func testCancelRestoresPreviousApplicationOnceAndCloseIsIdempotent() throws {
        var restoreCount = 0
        let manager = ScreenshotSelectionOverlayManager(
            activateApplication: false,
            restorePreviousApplication: { restoreCount += 1 }
        )
        try manager.show(frames: [try frame(id: 1, x: 0)], state: .empty)
        manager.close(cancelled: true)
        manager.close(cancelled: true)
        XCTAssertEqual(restoreCount, 1)
        XCTAssertEqual(manager.panelCount, 0)
    }

    private func frame(id: CGDirectDisplayID, x: CGFloat) throws -> DisplayCaptureFrame {
        guard let context = CGContext(
            data: nil,
            width: 100,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 400,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw OverlayTestError.imageCreation
        }
        return DisplayCaptureFrame(
            geometry: DisplayCaptureGeometry(
                displayID: id,
                globalFramePoints: CGRect(x: x, y: 0, width: 100, height: 100),
                pixelSize: CGSize(width: 100, height: 100)
            ),
            image: image
        )
    }

    private enum OverlayTestError: Error { case imageCreation }
}
