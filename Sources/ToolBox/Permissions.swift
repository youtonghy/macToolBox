import ApplicationServices
import AppKit
import CoreGraphics
import IOKit
import IOKit.hid

/// Handles TCC permission checks / prompts used by ToolBox.
///
/// - Input Monitoring: required for `CGEvent.tapCreate` media-key interception.
///   Prefer `CGPreflightListenEventAccess` / `CGRequestListenEventAccess`.
/// - Accessibility: still useful as a fallback signal on some macOS builds, and
///   for any future AX-based paths. Media-key taps primarily need Input Monitoring.
enum Permissions {

    enum InputMonitoringStatus: Equatable {
        case granted
        case denied
        case unknown

        var isTrusted: Bool { self == .granted }

        var label: String {
            switch self {
            case .granted:
                return "已授权"
            case .denied:
                return "未授权"
            case .unknown:
                return "待确认"
            }
        }
    }

    // MARK: - Input Monitoring

    /// Best-effort Input Monitoring status.
    ///
    /// Uses CoreGraphics preflight first (the API that maps to the Input Monitoring
    /// privacy pane for event taps). Falls back to IOHID when preflight is false so
    /// we can distinguish "explicitly denied" from "never asked / unknown".
    static var inputMonitoringStatus: InputMonitoringStatus {
        if CGPreflightListenEventAccess() {
            return .granted
        }

        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        switch access {
        case kIOHIDAccessTypeGranted:
            // Some builds report IOHID granted while CG preflight is still false
            // until the process is restarted. Treat as granted for UI, but callers
            // should still verify that the event tap can be created.
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

    /// Requests Input Monitoring access. May show a system prompt and/or add the
    /// app to System Settings → Privacy & Security → Input Monitoring.
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        if CGPreflightListenEventAccess() {
            return true
        }
        // Both paths can surface the app in the Input Monitoring list.
        let cgGranted = CGRequestListenEventAccess()
        let ioGranted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        return cgGranted || ioGranted || CGPreflightListenEventAccess()
    }

    // MARK: - Accessibility

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    @discardableResult
    static func requestAccessibilityOnce() -> Bool {
        let opts: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: kCFBooleanTrue as Any
        ]
        return AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    /// Polls accessibility trust (debounced — Sequoia/Tahoe can return stale
    /// `false` reads), calling `completion` on the main thread.
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

    /// Polls Input Monitoring until granted or timeout.
    static func awaitInputMonitoring(
        timeout: TimeInterval = 60,
        completion: @escaping (Bool) -> Void
    ) {
        pollTrust(
            timeout: timeout,
            isTrusted: { CGPreflightListenEventAccess() },
            completion: completion
        )
    }

    // MARK: - Settings deep links

    static func openInputMonitoringSettings() {
        openPrivacyPane(anchors: [
            "Privacy_ListenEvent",
            "Privacy_InputMonitoring"
        ])
    }

    static func openAccessibilitySettings() {
        openPrivacyPane(anchors: [
            "Privacy_Accessibility"
        ])
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
                    // Debounce: require two consecutive true reads.
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
        // Prefer modern System Settings URLs first, then legacy System Preferences.
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
