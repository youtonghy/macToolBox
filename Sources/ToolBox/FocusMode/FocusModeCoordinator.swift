import Combine
import CoreGraphics
import Foundation

@MainActor
protocol FocusModeSystemObserving: AnyObject {
    var onChange: (() -> Void)? { get set }
    var snapshot: FocusSystemSnapshot { get }

    func start()
    func stop()
    func requestAccessibilityPermission()
    func openAccessibilitySettings()
}

@MainActor
protocol FocusOverlayManaging: AnyObject {
    var dimmedDisplayIDs: Set<CGDirectDisplayID> { get }

    func apply(
        screens: [FocusScreenGeometry],
        focusedDisplayID: CGDirectDisplayID?,
        opacity: Double
    )
    func clear()
}

@MainActor
final class FocusModeCoordinator: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var overlayOpacity: Double
    @Published private(set) var permissionState: FocusPermissionState

    private let store: FocusModeStore
    private let systemObserver: any FocusModeSystemObserving
    private let overlayManager: any FocusOverlayManaging
    private let screensProvider: () -> [FocusScreenGeometry]
    private let ownProcessID: pid_t

    private var hasStarted = false
    private var observerIsRunning = false
    private var lastExternalDisplayID: CGDirectDisplayID?
    private var lastOverlayState: OverlayState?

    init(
        store: FocusModeStore = FocusModeStore(),
        systemObserver: any FocusModeSystemObserving,
        overlayManager: any FocusOverlayManaging,
        screensProvider: @escaping () -> [FocusScreenGeometry],
        ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) {
        let configuration = store.load()
        self.store = store
        self.systemObserver = systemObserver
        self.overlayManager = overlayManager
        self.screensProvider = screensProvider
        self.ownProcessID = ownProcessID
        isEnabled = configuration.isEnabled
        overlayOpacity = configuration.overlayOpacity
        permissionState = systemObserver.snapshot.accessibilityTrusted ? .granted : .missing
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        systemObserver.onChange = { [weak self] in
            self?.handleSystemChange()
        }

        let snapshot = systemObserver.snapshot
        updatePermissionState(from: snapshot)
        guard isEnabled else {
            transitionToClear()
            return
        }
        startObserverIfNeeded()
        reconcile(snapshot: snapshot)
    }

    func stop() {
        guard hasStarted else { return }
        hasStarted = false
        systemObserver.onChange = nil
        stopObserverIfNeeded()
        overlayManager.clear()
        lastOverlayState = nil
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        persistConfiguration()

        guard enabled else {
            stopObserverIfNeeded()
            transitionToClear()
            return
        }

        let snapshot = systemObserver.snapshot
        updatePermissionState(from: snapshot)
        if permissionState == .missing {
            systemObserver.requestAccessibilityPermission()
        }
        guard hasStarted else { return }
        startObserverIfNeeded()
        reconcile(snapshot: snapshot)
    }

    func setOverlayOpacity(_ opacity: Double) {
        let normalized = FocusModeStore.normalizedOpacity(opacity)
        guard normalized != overlayOpacity else { return }
        overlayOpacity = normalized
        persistConfiguration()
        if hasStarted, isEnabled {
            reconcile(snapshot: systemObserver.snapshot)
        }
    }

    func requestAccessibilityPermission() {
        systemObserver.requestAccessibilityPermission()
    }

    func openAccessibilitySettings() {
        systemObserver.openAccessibilitySettings()
    }

    private func handleSystemChange() {
        let snapshot = systemObserver.snapshot
        updatePermissionState(from: snapshot)
        if hasStarted, isEnabled {
            reconcile(snapshot: snapshot)
        }
    }

    private func reconcile(snapshot: FocusSystemSnapshot) {
        let screens = screensProvider()
        guard !snapshot.isSleeping, screens.count > 1 else {
            transitionToClear()
            return
        }

        let focusedDisplayID = FocusTargetResolver.resolve(
            screens: screens,
            snapshot: snapshot,
            ownProcessID: ownProcessID,
            lastExternalDisplayID: lastExternalDisplayID
        )
        if snapshot.frontmostApplicationPID != ownProcessID,
           let focusedDisplayID {
            lastExternalDisplayID = focusedDisplayID
        }

        let state = OverlayState(
            screens: screens,
            focusedDisplayID: focusedDisplayID,
            opacity: overlayOpacity
        )
        guard state != lastOverlayState else { return }
        overlayManager.apply(
            screens: screens,
            focusedDisplayID: focusedDisplayID,
            opacity: overlayOpacity
        )
        lastOverlayState = state
    }

    private func transitionToClear() {
        let state = OverlayState.clear
        guard state != lastOverlayState else { return }
        overlayManager.clear()
        lastOverlayState = state
    }

    private func startObserverIfNeeded() {
        guard hasStarted, !observerIsRunning else { return }
        systemObserver.start()
        observerIsRunning = true
    }

    private func stopObserverIfNeeded() {
        guard observerIsRunning else { return }
        systemObserver.stop()
        observerIsRunning = false
    }

    private func updatePermissionState(from snapshot: FocusSystemSnapshot) {
        permissionState = snapshot.accessibilityTrusted ? .granted : .missing
    }

    private func persistConfiguration() {
        store.save(FocusModeConfiguration(
            isEnabled: isEnabled,
            overlayOpacity: overlayOpacity
        ))
    }
}

private struct OverlayState: Equatable {
    var screens: [FocusScreenGeometry]
    var focusedDisplayID: CGDirectDisplayID?
    var opacity: Double

    static let clear = OverlayState(
        screens: [],
        focusedDisplayID: nil,
        opacity: 0
    )
}
