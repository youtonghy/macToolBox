import CoreGraphics
import ApplicationServices
import XCTest
@testable import ToolBox

@MainActor
final class FocusModeCoordinatorTests: XCTestCase {
    private let screens = [
        FocusScreenGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1_000, height: 1_080)),
        FocusScreenGeometry(id: 2, frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 1_080)),
    ]

    func testPersistedEnabledStateStartsWithoutPromptingAndAppliesAXFocus() {
        let harness = makeHarness(
            configuration: FocusModeConfiguration(isEnabled: true, overlayOpacity: 0.62),
            snapshot: trustedSnapshot(focusedDisplayID: 2)
        )

        harness.coordinator.start()

        XCTAssertTrue(harness.coordinator.isEnabled)
        XCTAssertEqual(harness.coordinator.overlayOpacity, 0.62)
        XCTAssertEqual(harness.coordinator.permissionState, .granted)
        XCTAssertEqual(harness.observer.startCount, 1)
        XCTAssertEqual(harness.observer.permissionRequestCount, 0)
        XCTAssertEqual(harness.overlays.dimmedDisplayIDs, [1])
    }

    func testUserEnablePromptsOnceButImmediatelyUsesMouseFallback() {
        let harness = makeHarness(
            configuration: FocusModeConfiguration(isEnabled: false, overlayOpacity: 0.55),
            snapshot: FocusSystemSnapshot(
                frontmostApplicationPID: 42,
                accessibilityTrusted: false,
                axFocusedWindowFrame: nil,
                mouseLocation: CGPoint(x: 1_500, y: 500)
            )
        )
        harness.coordinator.start()

        harness.coordinator.setEnabled(true)
        harness.coordinator.setEnabled(true)

        XCTAssertTrue(harness.coordinator.isEnabled)
        XCTAssertEqual(harness.coordinator.permissionState, .missing)
        XCTAssertEqual(harness.observer.permissionRequestCount, 1)
        XCTAssertEqual(harness.observer.startCount, 1)
        XCTAssertEqual(harness.overlays.dimmedDisplayIDs, [1])
        XCTAssertTrue(harness.store.load().isEnabled)
    }

    func testPermissionUpgradeUsesAXFocusWithoutRetoggling() {
        let harness = makeHarness(
            configuration: FocusModeConfiguration(isEnabled: true, overlayOpacity: 0.55),
            snapshot: FocusSystemSnapshot(
                frontmostApplicationPID: 42,
                accessibilityTrusted: false,
                axFocusedWindowFrame: nil,
                mouseLocation: CGPoint(x: 1_500, y: 500)
            )
        )
        harness.coordinator.start()
        XCTAssertEqual(harness.overlays.dimmedDisplayIDs, [1])

        harness.observer.emit(trustedSnapshot(focusedDisplayID: 1))

        XCTAssertTrue(harness.coordinator.isEnabled)
        XCTAssertEqual(harness.coordinator.permissionState, .granted)
        XCTAssertEqual(harness.overlays.dimmedDisplayIDs, [2])
    }

    func testOwnApplicationFocusPreservesLastExternalDisplay() {
        let harness = makeHarness(
            configuration: FocusModeConfiguration(isEnabled: true, overlayOpacity: 0.55),
            snapshot: trustedSnapshot(focusedDisplayID: 1)
        )
        harness.coordinator.start()
        XCTAssertEqual(harness.overlays.dimmedDisplayIDs, [2])

        harness.observer.emit(FocusSystemSnapshot(
            frontmostApplicationPID: 99,
            accessibilityTrusted: true,
            axFocusedWindowFrame: nil,
            mouseLocation: CGPoint(x: 1_500, y: 500)
        ))

        XCTAssertEqual(harness.overlays.dimmedDisplayIDs, [2])
    }

    func testOpacityClampsPersistsAndUpdatesExistingTarget() {
        let harness = makeHarness(
            configuration: FocusModeConfiguration(isEnabled: true, overlayOpacity: 0.55),
            snapshot: trustedSnapshot(focusedDisplayID: 1)
        )
        harness.coordinator.start()
        let originalIDs = harness.overlays.dimmedDisplayIDs

        harness.coordinator.setOverlayOpacity(0.95)

        XCTAssertEqual(harness.coordinator.overlayOpacity, 0.85)
        XCTAssertEqual(harness.store.load().overlayOpacity, 0.85)
        XCTAssertEqual(harness.overlays.opacity, 0.85)
        XCTAssertEqual(harness.overlays.dimmedDisplayIDs, originalIDs)
    }

    func testDisabledSleepingAndSingleScreenStatesClearOverlays() {
        let harness = makeHarness(
            configuration: FocusModeConfiguration(isEnabled: true, overlayOpacity: 0.55),
            snapshot: trustedSnapshot(focusedDisplayID: 1)
        )
        harness.coordinator.start()
        XCTAssertEqual(harness.overlays.dimmedDisplayIDs, [2])

        harness.observer.emit(FocusSystemSnapshot(
            frontmostApplicationPID: 42,
            accessibilityTrusted: true,
            axFocusedWindowFrame: nil,
            mouseLocation: CGPoint(x: 500, y: 500),
            isSleeping: true
        ))
        XCTAssertTrue(harness.overlays.dimmedDisplayIDs.isEmpty)

        harness.observer.emit(trustedSnapshot(focusedDisplayID: 1))
        harness.screenProvider.screens = [screens[0]]
        harness.observer.emit(trustedSnapshot(focusedDisplayID: 1))
        XCTAssertTrue(harness.overlays.dimmedDisplayIDs.isEmpty)

        harness.screenProvider.screens = screens
        harness.observer.emit(trustedSnapshot(focusedDisplayID: 1))
        harness.coordinator.setEnabled(false)
        XCTAssertTrue(harness.overlays.dimmedDisplayIDs.isEmpty)
        XCTAssertEqual(harness.observer.stopCount, 1)
    }

    func testIdenticalSnapshotsAreDeduplicatedAndLatestFocusWins() {
        let harness = makeHarness(
            configuration: FocusModeConfiguration(isEnabled: true, overlayOpacity: 0.55),
            snapshot: trustedSnapshot(focusedDisplayID: 1)
        )
        harness.coordinator.start()
        let initialApplyCount = harness.overlays.applyCount

        harness.observer.emit(trustedSnapshot(focusedDisplayID: 1))
        XCTAssertEqual(harness.overlays.applyCount, initialApplyCount)

        harness.observer.emit(trustedSnapshot(focusedDisplayID: 2))
        harness.observer.emit(trustedSnapshot(focusedDisplayID: 1))

        XCTAssertEqual(harness.overlays.dimmedDisplayIDs, [2])
    }

    func testStartAndStopAreIdempotent() {
        let harness = makeHarness(
            configuration: FocusModeConfiguration(isEnabled: true, overlayOpacity: 0.55),
            snapshot: trustedSnapshot(focusedDisplayID: 1)
        )

        harness.coordinator.start()
        harness.coordinator.start()
        harness.coordinator.stop()
        harness.coordinator.stop()

        XCTAssertEqual(harness.observer.startCount, 1)
        XCTAssertEqual(harness.observer.stopCount, 1)
        XCTAssertTrue(harness.overlays.dimmedDisplayIDs.isEmpty)
    }

    func testRealOverlayManagerReconcilesDesiredWindows() {
        let manager = FocusOverlayManager(animationDuration: 0)

        manager.apply(screens: screens, focusedDisplayID: 1, opacity: 0.55)
        XCTAssertEqual(manager.dimmedDisplayIDs, [2])

        manager.apply(screens: screens, focusedDisplayID: 2, opacity: 0.55)
        XCTAssertEqual(manager.dimmedDisplayIDs, [1])

        manager.apply(screens: screens, focusedDisplayID: 2, opacity: 0.80)
        XCTAssertEqual(manager.dimmedDisplayIDs, [1])

        manager.apply(screens: screens, focusedDisplayID: nil, opacity: 0.80)
        XCTAssertTrue(manager.dimmedDisplayIDs.isEmpty)

        manager.clear()
        XCTAssertTrue(manager.dimmedDisplayIDs.isEmpty)
    }

    func testAXRegistrationPolicyClassifiesRecoverableAndDiagnosticErrors() {
        XCTAssertEqual(FocusAXRegistrationPolicy.classify(.success), .installed)
        XCTAssertEqual(
            FocusAXRegistrationPolicy.classify(.notificationAlreadyRegistered),
            .installed
        )
        XCTAssertEqual(
            FocusAXRegistrationPolicy.classify(.notificationUnsupported),
            .recoverable
        )
        XCTAssertEqual(FocusAXRegistrationPolicy.classify(.cannotComplete), .failed)
        XCTAssertEqual(FocusAXRegistrationPolicy.classify(.invalidUIElement), .failed)
    }

    private func trustedSnapshot(focusedDisplayID: CGDirectDisplayID) -> FocusSystemSnapshot {
        let x: CGFloat = focusedDisplayID == 1 ? 100 : 1_100
        return FocusSystemSnapshot(
            frontmostApplicationPID: 42,
            accessibilityTrusted: true,
            axFocusedWindowFrame: CGRect(x: x, y: 180, width: 700, height: 700),
            mouseLocation: CGPoint(x: 500, y: 500)
        )
    }

    private func makeHarness(
        configuration: FocusModeConfiguration,
        snapshot: FocusSystemSnapshot
    ) -> FocusModeHarness {
        let suiteName = "FocusModeCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = FocusModeStore(defaults: defaults)
        store.save(configuration)
        let observer = FakeFocusModeSystemObserver(snapshot: snapshot)
        let overlays = FakeFocusOverlayManager()
        let screenProvider = FakeFocusScreenProvider(screens: screens)
        let coordinator = FocusModeCoordinator(
            store: store,
            systemObserver: observer,
            overlayManager: overlays,
            screensProvider: { screenProvider.screens },
            ownProcessID: 99
        )
        return FocusModeHarness(
            coordinator: coordinator,
            observer: observer,
            overlays: overlays,
            screenProvider: screenProvider,
            store: store,
            defaults: defaults,
            suiteName: suiteName
        )
    }
}

@MainActor
private final class FakeFocusModeSystemObserver: FocusModeSystemObserving {
    var onChange: (() -> Void)?
    private(set) var snapshot: FocusSystemSnapshot
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var permissionRequestCount = 0
    private(set) var settingsOpenCount = 0

    init(snapshot: FocusSystemSnapshot) {
        self.snapshot = snapshot
    }

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func requestAccessibilityPermission() { permissionRequestCount += 1 }
    func openAccessibilitySettings() { settingsOpenCount += 1 }

    func emit(_ snapshot: FocusSystemSnapshot) {
        self.snapshot = snapshot
        onChange?()
    }
}

@MainActor
private final class FakeFocusOverlayManager: FocusOverlayManaging {
    private(set) var dimmedDisplayIDs: Set<CGDirectDisplayID> = []
    private(set) var opacity = 0.0
    private(set) var applyCount = 0

    func apply(
        screens: [FocusScreenGeometry],
        focusedDisplayID: CGDirectDisplayID?,
        opacity: Double
    ) {
        applyCount += 1
        self.opacity = opacity
        guard screens.count > 1, let focusedDisplayID else {
            dimmedDisplayIDs = []
            return
        }
        dimmedDisplayIDs = Set(screens.lazy.map(\.id).filter { $0 != focusedDisplayID })
    }

    func clear() {
        dimmedDisplayIDs = []
    }
}

private final class FakeFocusScreenProvider {
    var screens: [FocusScreenGeometry]

    init(screens: [FocusScreenGeometry]) {
        self.screens = screens
    }
}

@MainActor
private final class FocusModeHarness {
    let coordinator: FocusModeCoordinator
    let observer: FakeFocusModeSystemObserver
    let overlays: FakeFocusOverlayManager
    let screenProvider: FakeFocusScreenProvider
    let store: FocusModeStore
    private let defaults: UserDefaults
    private let suiteName: String

    init(
        coordinator: FocusModeCoordinator,
        observer: FakeFocusModeSystemObserver,
        overlays: FakeFocusOverlayManager,
        screenProvider: FakeFocusScreenProvider,
        store: FocusModeStore,
        defaults: UserDefaults,
        suiteName: String
    ) {
        self.coordinator = coordinator
        self.observer = observer
        self.overlays = overlays
        self.screenProvider = screenProvider
        self.store = store
        self.defaults = defaults
        self.suiteName = suiteName
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
