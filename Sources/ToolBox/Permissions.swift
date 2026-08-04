import ApplicationServices
import AppKit
import CoreGraphics
import IOKit
import IOKit.hid

/// Handles TCC permission checks / prompts used by ToolBox.
///
/// Media-key interception uses `CGEvent.tapCreate` with `.defaultTap` so events can
/// be swallowed. On current macOS that typically needs:
/// - **Input Monitoring** (listen / event-tap identity)
/// - **Accessibility** (modify / suppress the event stream)
enum Permissions {

    // MARK: - Event posting

    static var canPostEvents: Bool {
        CGPreflightPostEventAccess()
    }

    /// Requests event-posting access only from an explicit user action.
    @discardableResult
    static func requestEventPosting() -> Bool {
        CGRequestPostEventAccess() || CGPreflightPostEventAccess()
    }

    // MARK: - Screen Capture

    static var isScreenCaptureTrusted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Prompts only when invoked from a user-initiated capture action.
    @discardableResult
    static func requestScreenCapture() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        return CGRequestScreenCaptureAccess() || CGPreflightScreenCaptureAccess()
    }

    static func openScreenCaptureSettings() {
        openPrivacyPane(anchors: ["Privacy_ScreenCapture", "Privacy_ScreenRecording"])
    }

    enum InputMonitoringStatus: Equatable {
        case granted
        case denied
        case unknown

        var isTrusted: Bool { self == .granted }

        var label: String {
            switch self {
            case .granted: return "已授权"
            case .denied: return "未授权"
            case .unknown: return "待确认"
            }
        }
    }

    /// What the media-key path is still missing.
    enum MediaKeyPermissionGap: Equatable {
        case none
        case inputMonitoring
        case accessibility
        case both
        /// Preflight APIs report granted, but tap creation still fails (often needs process restart).
        case restartRequired

        var needsUserAction: Bool {
            switch self {
            case .none:
                return false
            case .inputMonitoring, .accessibility, .both, .restartRequired:
                return true
            }
        }
    }

    // MARK: - Input Monitoring

    static var inputMonitoringStatus: InputMonitoringStatus {
        if CGPreflightListenEventAccess() {
            return .granted
        }

        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        switch access {
        case kIOHIDAccessTypeGranted:
            return .granted
        case kIOHIDAccessTypeDenied:
            return .denied
        default:
            return .unknown
        }
    }

    static var isInputMonitoringTrusted: Bool {
        inputMonitoringStatus.isTrusted
    }

    /// Registers the current process with TCC for Input Monitoring so it appears
    /// in System Settings → Privacy & Security → Input Monitoring.
    @discardableResult
    static func registerInputMonitoring() -> Bool {
        if CGPreflightListenEventAccess() {
            return true
        }
        let cgGranted = CGRequestListenEventAccess()
        let ioGranted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        return cgGranted || ioGranted || CGPreflightListenEventAccess()
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool {
        registerInputMonitoring()
    }

    // MARK: - Accessibility

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    /// Registers / prompts for Accessibility so ToolBox appears in the Accessibility list.
    /// - Parameter prompt: when true, macOS may show the system trust dialog once.
    @discardableResult
    static func registerAccessibility(prompt: Bool = false) -> Bool {
        if prompt {
            let opts: NSDictionary = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: kCFBooleanTrue as Any
            ]
            return AXIsProcessTrustedWithOptions(opts as CFDictionary)
        }
        // Touch the API without prompting so TCC materializes a row when possible.
        return AXIsProcessTrustedWithOptions(nil)
    }

    @discardableResult
    static func requestAccessibilityOnce() -> Bool {
        registerAccessibility(prompt: true)
    }

    // MARK: - Combined media-key gap

    /// Best-effort classification of why a media-key event tap cannot be installed.
    static func mediaKeyPermissionGap(
        canCreateListenOnlyTap: Bool?,
        canCreateDefaultTap: Bool?
    ) -> MediaKeyPermissionGap {
        mediaKeyPermissionGap(
            canCreateListenOnlyTap: canCreateListenOnlyTap,
            canCreateDefaultTap: canCreateDefaultTap,
            inputMonitoringTrusted: isInputMonitoringTrusted,
            accessibilityTrusted: isAccessibilityTrusted
        )
    }

    static func mediaKeyPermissionGap(
        canCreateListenOnlyTap: Bool?,
        canCreateDefaultTap: Bool?,
        inputMonitoringTrusted: Bool,
        accessibilityTrusted: Bool
    ) -> MediaKeyPermissionGap {
        if canCreateDefaultTap == true {
            return .none
        }

        // Empirical split: listen-only often works with Input Monitoring alone;
        // default (modify/swallow) commonly also needs Accessibility.
        if canCreateListenOnlyTap == true {
            return accessibilityTrusted ? .restartRequired : .accessibility
        }

        switch (inputMonitoringTrusted, accessibilityTrusted) {
        case (true, true):
            return .restartRequired
        case (false, true):
            return .inputMonitoring
        case (true, false):
            return .accessibility
        case (false, false):
            return .both
        }
    }

    // MARK: - Polling

    static func awaitAccessibility(
        timeout: TimeInterval = 60,
        completion: @escaping (Bool) -> Void
    ) {
        pollTrust(
            timeout: timeout,
            isTrusted: { AXIsProcessTrustedWithOptions(nil) },
            completion: completion
        )
    }

    static func awaitInputMonitoring(
        timeout: TimeInterval = 60,
        completion: @escaping (Bool) -> Void
    ) {
        pollTrust(
            timeout: timeout,
            isTrusted: {
                CGPreflightListenEventAccess()
                    || IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            },
            completion: completion
        )
    }

    static func awaitMediaKeyPermissions(
        timeout: TimeInterval = 90,
        completion: @escaping (Bool) -> Void
    ) {
        pollTrust(
            timeout: timeout,
            isTrusted: { isInputMonitoringTrusted && isAccessibilityTrusted },
            completion: completion
        )
    }

    // MARK: - Settings deep links

    /// Opens the most relevant privacy pane for media keys, registering ToolBox first
    /// so the list is pre-filled (user only needs to flip the switch).
    static func openMediaKeyPermissionSettings(
        gap: MediaKeyPermissionGap = .both,
        completion: (() -> Void)? = nil
    ) {
        switch gap {
        case .accessibility, .restartRequired:
            // Restart-required often still benefits from re-confirming Accessibility.
            _ = registerAccessibility(prompt: false)
            // Soft prompt once helps some macOS builds materialize the row.
            if !isAccessibilityTrusted {
                _ = registerAccessibility(prompt: true)
            }
            _ = registerInputMonitoring()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                openPrivacyPane(anchors: ["Privacy_Accessibility"])
                completion?()
            }

        case .inputMonitoring:
            _ = registerInputMonitoring()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                openPrivacyPane(anchors: [
                    "Privacy_ListenEvent",
                    "Privacy_InputMonitoring"
                ])
                completion?()
            }

        case .both, .none:
            _ = registerInputMonitoring()
            _ = registerAccessibility(prompt: !isAccessibilityTrusted)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                // Accessibility is the more common missing piece for .defaultTap.
                // Input Monitoring is also registered so it appears if needed.
                openPrivacyPane(anchors: ["Privacy_Accessibility"])
                completion?()
            }
        }
    }

    static func openInputMonitoringSettings(completion: (() -> Void)? = nil) {
        openMediaKeyPermissionSettings(gap: .inputMonitoring, completion: completion)
    }

    static func openAccessibilitySettings(
        registerIfNeeded: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        if registerIfNeeded {
            _ = registerAccessibility(prompt: !isAccessibilityTrusted)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            openPrivacyPane(anchors: ["Privacy_Accessibility"])
            completion?()
        }
    }

    // MARK: - Private

    private static func pollTrust(
        timeout: TimeInterval,
        isTrusted: @escaping () -> Bool,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let deadline = Date().addingTimeInterval(timeout)
            var consecutive = 0
            while Date() < deadline {
                if isTrusted() {
                    consecutive += 1
                    if consecutive >= 2 {
                        DispatchQueue.main.async { completion(true) }
                        return
                    }
                } else {
                    consecutive = 0
                }
                Thread.sleep(forTimeInterval: 0.7)
            }
            DispatchQueue.main.async { completion(false) }
        }
    }

    private static func openPrivacyPane(anchors: [String]) {
        var candidates: [URL] = []
        for anchor in anchors {
            if let modern = URL(
                string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)"
            ) {
                candidates.append(modern)
            }
            if let legacy = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
            ) {
                candidates.append(legacy)
            }
        }

        for url in candidates where NSWorkspace.shared.open(url) {
            return
        }
    }
}
