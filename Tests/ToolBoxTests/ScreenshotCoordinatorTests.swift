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
        overlay.send(.adjustRegion(CGRect(x: 0, y: 0, width: 20, height: 20)))
        overlay.send(.confirm)
        await waitForPreview(coordinator)
        XCTAssertEqual(coordinator.state, .previewing)
        XCTAssertEqual(coordinator.frozenFrameCount, 0)
        XCTAssertNotNil(handedOff)
    }

    func testNormalCandidateClickAutomaticallyHandsOffToEditor() async throws {
        let overlay = FakeOverlay()
        var handedOff: CGImage?
        let coordinator = ScreenshotCoordinator(
            permission: FakePermission(granted: true),
            captureProvider: FakeCaptureProvider(result: .success([try frame()])),
            overlay: overlay,
            editorHandoff: { handedOff = $0 }
        )
        await coordinator.startRegionCapture()

        overlay.send(.click(candidate(), additive: false))
        await waitForPreview(coordinator)

        XCTAssertEqual(coordinator.state, .previewing)
        XCTAssertNotNil(handedOff)
    }

    func testCandidateClickDefersOverlayTeardownUntilActionReturns() async throws {
        let overlay = FakeOverlay()
        let coordinator = ScreenshotCoordinator(
            permission: FakePermission(granted: true),
            captureProvider: FakeCaptureProvider(result: .success([try frame()])),
            overlay: overlay
        )
        await coordinator.startRegionCapture()

        overlay.send(.click(candidate(), additive: false))

        XCTAssertFalse(overlay.closedDuringAction)
        XCTAssertEqual(overlay.closeCount, 0)
        XCTAssertEqual(coordinator.state, .selecting)
        await waitForPreview(coordinator)
        XCTAssertEqual(overlay.closeCount, 1)
        XCTAssertEqual(coordinator.state, .previewing)
    }

    func testCompletedManualDragAutomaticallyHandsOffToEditor() async throws {
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
        await waitForPreview(coordinator)

        XCTAssertEqual(coordinator.state, .previewing)
        XCTAssertNotNil(handedOff)
    }

    func testRegionAdjustmentDoesNotLeaveSelectionStage() async throws {
        let overlay = FakeOverlay()
        let coordinator = ScreenshotCoordinator(
            permission: FakePermission(granted: true),
            captureProvider: FakeCaptureProvider(result: .success([try frame()])),
            overlay: overlay
        )
        await coordinator.startRegionCapture()

        overlay.send(.adjustRegion(CGRect(x: 0, y: 0, width: 20, height: 20)))

        XCTAssertEqual(coordinator.state, .selecting)
        XCTAssertEqual(overlay.updatedStates.last?.captureBounds, CGRect(x: 0, y: 0, width: 20, height: 20))
    }

    func testHoverCandidateCyclesThroughResolvedHierarchyAndWraps() async throws {
        let overlay = FakeOverlay()
        let child = candidate(
            hierarchyIndex: 0,
            rect: CGRect(x: 4, y: 4, width: 8, height: 8)
        )
        let parent = candidate(
            hierarchyIndex: 1,
            rect: CGRect(x: 0, y: 0, width: 20, height: 20)
        )
        let coordinator = ScreenshotCoordinator(
            permission: FakePermission(granted: true),
            captureProvider: FakeCaptureProvider(result: .success([try frame()])),
            overlay: overlay,
            candidateResolver: { _, _ in [child, parent] }
        )
        await coordinator.startRegionCapture()

        overlay.sendHover(CGPoint(x: 8, y: 8))
        await waitForHoveredCandidate(overlay)
        XCTAssertEqual(overlay.updatedStates.last?.hoveredCandidate, child)

        overlay.send(.cycleCandidate(1))
        XCTAssertEqual(overlay.updatedStates.last?.hoveredCandidate, parent)
        overlay.send(.cycleCandidate(1))
        XCTAssertEqual(overlay.updatedStates.last?.hoveredCandidate, child)
        overlay.send(.cycleCandidate(-1))
        XCTAssertEqual(overlay.updatedStates.last?.hoveredCandidate, parent)
    }

    func testScrollModeSelectionStartsLongCaptureInsteadOfEditorHandoff() async throws {
        let overlay = FakeOverlay()
        var handedOff: CGImage?
        let coordinator = ScreenshotCoordinator(
            permission: FakePermission(granted: true),
            captureProvider: FakeCaptureProvider(result: .success([try frame()])),
            overlay: overlay,
            editorHandoff: { handedOff = $0 }
        )
        await coordinator.startRegionCapture()

        overlay.send(.setCaptureMode(.scrollCapture))
        XCTAssertEqual(overlay.updatedStates.last?.captureMode, .scrollCapture)
        overlay.send(.manualDrag(CGRect(x: 0, y: 0, width: 20, height: 20)))
        for _ in 0..<10 where coordinator.state == .selecting {
            await Task.yield()
        }

        XCTAssertNil(handedOff)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(coordinator.lastError, .longCaptureFailed)
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

    private func candidate(
        hierarchyIndex: Int = 0,
        rect: CGRect = CGRect(x: 0, y: 0, width: 20, height: 20)
    ) -> SelectionCandidate {
        SelectionCandidate(
            providerIdentity: "test",
            source: .accessibility,
            ownerPID: 42,
            windowID: 7,
            displayID: 1,
            topologyGeneration: 1,
            role: "AXButton",
            title: "test",
            hierarchyIndex: hierarchyIndex,
            globalRect: rect
        )
    }

    private func waitForPreview(_ coordinator: ScreenshotCoordinator) async {
        for _ in 0..<10 where coordinator.state == .selecting {
            await Task.yield()
        }
    }

    private func waitForHoveredCandidate(_ overlay: FakeOverlay) async {
        for _ in 0..<10 where overlay.updatedStates.last?.hoveredCandidate == nil {
            await Task.yield()
        }
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
    var updatedStates: [SelectionSessionState] = []
    var action: ((SelectionAction) -> Void)?
    var hover: ((CGPoint) -> Void)?
    private var isSendingAction = false
    private(set) var closedDuringAction = false
    func show(frames: [DisplayCaptureFrame], state: SelectionSessionState, onAction: @escaping (SelectionAction) -> Void, onHover: @escaping (CGPoint) -> Void, onCancel: @escaping () -> Void) throws {
        showCount += 1
        action = onAction
        hover = onHover
    }
    func beginInteraction(on displayID: CGDirectDisplayID) { bringForwardCount += 1 }
    func update(state: SelectionSessionState) { updatedStates.append(state) }
    func close(cancelled: Bool) {
        closeCount += 1
        closedDuringAction = closedDuringAction || isSendingAction
    }
    func send(_ value: SelectionAction) {
        isSendingAction = true
        action?(value)
        isSendingAction = false
    }
    func sendHover(_ point: CGPoint) { hover?(point) }
}
