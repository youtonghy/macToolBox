import CoreGraphics
import XCTest
@testable import ToolBox

@MainActor
final class ScreenshotCoordinatorTests: XCTestCase {
    func testDeniedPermissionDoesNotCaptureOrShowOverlay() async {
        let permission = FakePermission(granted: false, requestResult: false)
        let capture = FakeCaptureProvider(result: .success([]))
        let overlay = FakeOverlay()
        let coordinator = ScreenshotCoordinator(permission: permission, captureProvider: capture, overlay: overlay)

        await coordinator.startRegionCapture()

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(coordinator.lastError, .permissionDenied)
        XCTAssertEqual(capture.callCount, 0)
        XCTAssertEqual(overlay.showCount, 0)
    }

    func testSuccessfulStartEntersSelectingAndRepeatedStartBringsForward() async throws {
        let overlay = FakeOverlay()
        let coordinator = ScreenshotCoordinator(
            permission: FakePermission(granted: true),
            captureProvider: FakeCaptureProvider(result: .success([try frame()])),
            overlay: overlay
        )
        await coordinator.startRegionCapture()
        XCTAssertEqual(coordinator.state, .selecting)
        XCTAssertEqual(overlay.showCount, 1)
        await coordinator.startRegionCapture()
        XCTAssertEqual(overlay.bringForwardCount, 1)
        XCTAssertEqual(overlay.showCount, 1)
    }

    func testConfirmComposesReleasesFramesAndHandsOffImage() async throws {
        let overlay = FakeOverlay()
        var handedOff: CGImage?
        let coordinator = ScreenshotCoordinator(
            permission: FakePermission(granted: true),
            captureProvider: FakeCaptureProvider(result: .success([try frame()])),
            overlay: overlay,
            editorHandoff: { handedOff = $0 }
        )
        await coordinator.startRegionCapture()
        overlay.send(.manualDrag(CGRect(x: 0, y: 0, width: 20, height: 20)))
        overlay.send(.confirm)
        XCTAssertEqual(coordinator.state, .previewing)
        XCTAssertEqual(coordinator.frozenFrameCount, 0)
        XCTAssertNotNil(handedOff)
    }

    func testCaptureFailureAndCancelCleanUpIdempotently() async throws {
        let failed = ScreenshotCoordinator(
            permission: FakePermission(granted: true),
            captureProvider: FakeCaptureProvider(result: .failure(.frozenFrameBudgetExceeded)),
            overlay: FakeOverlay()
        )
        await failed.startRegionCapture()
        XCTAssertEqual(failed.state, .idle)
        XCTAssertEqual(failed.lastError, .capture(.frozenFrameBudgetExceeded))

        let overlay = FakeOverlay()
        let active = ScreenshotCoordinator(
            permission: FakePermission(granted: true),
            captureProvider: FakeCaptureProvider(result: .success([try frame()])),
            overlay: overlay
        )
        await active.startRegionCapture()
        active.cancel()
        active.cancel()
        XCTAssertEqual(active.state, .idle)
        XCTAssertEqual(overlay.closeCount, 1)
    }

    private func frame() throws -> DisplayCaptureFrame {
        guard let context = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { throw TestError.image }
        return DisplayCaptureFrame(
            geometry: .init(displayID: 1, globalFramePoints: CGRect(x: 0, y: 0, width: 20, height: 20), pixelSize: CGSize(width: 20, height: 20)),
            image: image
        )
    }

    private enum TestError: Error { case image }
}

@MainActor private final class FakePermission: ScreenCapturePermissionProviding {
    var granted: Bool
    let requestResult: Bool
    init(granted: Bool, requestResult: Bool = true) { self.granted = granted; self.requestResult = requestResult }
    var state: ScreenCapturePermissionState { granted ? .granted : .denied }
    func requestAccess() -> Bool { requestResult }
    func openSettings() {}
}

@MainActor private final class FakeCaptureProvider: ScreenCaptureProviding {
    let result: Result<[DisplayCaptureFrame], ScreenshotCaptureError>
    var callCount = 0
    init(result: Result<[DisplayCaptureFrame], ScreenshotCaptureError>) { self.result = result }
    func captureDisplays() async throws -> [DisplayCaptureFrame] { callCount += 1; return try result.get() }
}

@MainActor private final class FakeOverlay: ScreenshotSelectionOverlayManaging {
    var showCount = 0
    var closeCount = 0
    var bringForwardCount = 0
    var action: ((SelectionAction) -> Void)?
    func show(frames: [DisplayCaptureFrame], state: SelectionSessionState, onAction: @escaping (SelectionAction) -> Void, onHover: @escaping (CGPoint) -> Void, onCancel: @escaping () -> Void) throws { showCount += 1; action = onAction }
    func beginInteraction(on displayID: CGDirectDisplayID) { bringForwardCount += 1 }
    func update(state: SelectionSessionState) {}
    func close(cancelled: Bool) { closeCount += 1 }
    func send(_ value: SelectionAction) { action?(value) }
}
