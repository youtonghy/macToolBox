import AppKit
import Combine

struct ShortcutPermissionSystem {
    let accessibilityTrusted: () -> Bool
    let inputMonitoringStatus: () -> Permissions.InputMonitoringStatus
    let screenCaptureTrusted: () -> Bool
    let canPostEvents: () -> Bool
    let requestAccessibility: () -> Bool
    let registerAccessibility: () -> Bool
    let openAccessibilitySettings: () -> Void
    let registerInputMonitoring: () -> Bool
    let openMediaKeySettings: (Permissions.MediaKeyPermissionGap) -> Void
    let requestScreenCapture: () -> Bool
    let openScreenCaptureSettings: () -> Void
    let requestEventPosting: () -> Bool

    init(
        accessibilityTrusted: @escaping () -> Bool,
        inputMonitoringStatus: @escaping () -> Permissions.InputMonitoringStatus,
        screenCaptureTrusted: @escaping () -> Bool,
        canPostEvents: @escaping () -> Bool,
        requestAccessibility: @escaping () -> Bool,
        registerAccessibility: @escaping () -> Bool = { false },
        openAccessibilitySettings: @escaping () -> Void,
        registerInputMonitoring: @escaping () -> Bool,
        openMediaKeySettings: @escaping (Permissions.MediaKeyPermissionGap) -> Void,
        requestScreenCapture: @escaping () -> Bool = { false },
        openScreenCaptureSettings: @escaping () -> Void = {},
        requestEventPosting: @escaping () -> Bool = { false }
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.inputMonitoringStatus = inputMonitoringStatus
        self.screenCaptureTrusted = screenCaptureTrusted
        self.canPostEvents = canPostEvents
        self.requestAccessibility = requestAccessibility
        self.registerAccessibility = registerAccessibility
        self.openAccessibilitySettings = openAccessibilitySettings
        self.registerInputMonitoring = registerInputMonitoring
        self.openMediaKeySettings = openMediaKeySettings
        self.requestScreenCapture = requestScreenCapture
        self.openScreenCaptureSettings = openScreenCaptureSettings
        self.requestEventPosting = requestEventPosting
    }

    static let live = ShortcutPermissionSystem(
        accessibilityTrusted: { Permissions.isAccessibilityTrusted },
        inputMonitoringStatus: { Permissions.inputMonitoringStatus },
        screenCaptureTrusted: { Permissions.isScreenCaptureTrusted },
        canPostEvents: { Permissions.canPostEvents },
        requestAccessibility: { Permissions.requestAccessibilityOnce() },
        registerAccessibility: { Permissions.registerAccessibility(prompt: false) },
        openAccessibilitySettings: {
            Permissions.openAccessibilitySettings(registerIfNeeded: false)
        },
        registerInputMonitoring: { Permissions.registerInputMonitoring() },
        openMediaKeySettings: { Permissions.openMediaKeyPermissionSettings(gap: $0) },
        requestScreenCapture: { Permissions.requestScreenCapture() },
        openScreenCaptureSettings: { Permissions.openScreenCaptureSettings() },
        requestEventPosting: { Permissions.requestEventPosting() }
    )
}

struct ShortcutPermissionSnapshot: Equatable {
    var accessibilityTrusted: Bool
    var inputMonitoringStatus: Permissions.InputMonitoringStatus
    var screenCaptureTrusted: Bool
    var canPostEvents: Bool
    var mediaKeyRouteRequested: Bool
    var mediaKeyRouteActive: Bool
    var listenOnlyTapAvailable: Bool?

    var mediaKeyPermissionGap: Permissions.MediaKeyPermissionGap {
        guard mediaKeyRouteRequested, !mediaKeyRouteActive else { return .none }
        return Permissions.mediaKeyPermissionGap(
            canCreateListenOnlyTap: listenOnlyTapAvailable,
            canCreateDefaultTap: mediaKeyRouteActive,
            inputMonitoringTrusted: inputMonitoringStatus.isTrusted,
            accessibilityTrusted: accessibilityTrusted
        )
    }
}

@MainActor
final class ShortcutPermissionCenter: ObservableObject {
    @Published private(set) var snapshot: ShortcutPermissionSnapshot
    var onApplicationDidBecomeActive: (() -> Void)?

    private let system: ShortcutPermissionSystem
    private let notificationCenter: NotificationCenter
    private var activationToken: NSObjectProtocol?

    init(
        system: ShortcutPermissionSystem = .live,
        notificationCenter: NotificationCenter = .default
    ) {
        self.system = system
        self.notificationCenter = notificationCenter
        snapshot = ShortcutPermissionSnapshot(
            accessibilityTrusted: system.accessibilityTrusted(),
            inputMonitoringStatus: system.inputMonitoringStatus(),
            screenCaptureTrusted: system.screenCaptureTrusted(),
            canPostEvents: system.canPostEvents(),
            mediaKeyRouteRequested: false,
            mediaKeyRouteActive: false,
            listenOnlyTapAvailable: nil
        )
    }

    func start() {
        guard activationToken == nil else { return }
        activationToken = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.onApplicationDidBecomeActive?()
            }
        }
        refresh()
    }

    func stop() {
        if let activationToken {
            notificationCenter.removeObserver(activationToken)
        }
        activationToken = nil
        onApplicationDidBecomeActive = nil
    }

    func refresh() {
        var next = snapshot
        next.accessibilityTrusted = system.accessibilityTrusted()
        next.inputMonitoringStatus = system.inputMonitoringStatus()
        next.screenCaptureTrusted = system.screenCaptureTrusted()
        next.canPostEvents = system.canPostEvents()
        publish(next)
    }

    func updateMediaKeyRoute(
        requested: Bool,
        active: Bool,
        listenOnlyTapAvailable: Bool?
    ) {
        var next = snapshot
        next.mediaKeyRouteRequested = requested
        next.mediaKeyRouteActive = active
        next.listenOnlyTapAvailable = listenOnlyTapAvailable
        publish(next)
    }

    func quietlyRegisterMediaKeyPermissions() {
        if snapshot.inputMonitoringStatus != .granted {
            _ = system.registerInputMonitoring()
        }
        if !snapshot.accessibilityTrusted {
            _ = system.registerAccessibility()
        }
        refresh()
    }

    func requestAccessibility() {
        let granted = system.requestAccessibility()
        refresh()
        if !granted {
            system.openAccessibilitySettings()
        }
    }

    func openMediaKeyPermissionSettings() {
        system.openMediaKeySettings(snapshot.mediaKeyPermissionGap)
    }

    func requestScreenCapture() {
        let granted = system.requestScreenCapture()
        refresh()
        if !granted {
            system.openScreenCaptureSettings()
        }
    }

    func requestEventPosting() {
        _ = system.requestEventPosting()
        refresh()
    }

    private func publish(_ next: ShortcutPermissionSnapshot) {
        guard next != snapshot else { return }
        snapshot = next
    }

    deinit {
        if let activationToken {
            notificationCenter.removeObserver(activationToken)
        }
    }
}
