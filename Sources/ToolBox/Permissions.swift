import ApplicationServices
import AppKit

/// Handles TCC permission checks/prompts.
/// - Input Monitoring: required for CGEventTap (listen) and IOHIDManagerOpen. There is no
///   public "am I trusted?" API, so we detect denial indirectly (nil tap / open error) and
///   deep-link to System Settings.
/// - Accessibility: requested once; some macOS builds also require it for taps.
enum Permissions {

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    @discardableResult
    static func requestAccessibilityOnce() -> Bool {
        let opts: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: kCFBooleanTrue as Any]
        return AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    /// Polls accessibility trust (debounced — Sequoia/Tahoe return stale `false` reads),
    /// calling `completion` on the main thread.
    static func awaitAccessibility(timeout: TimeInterval = 60,
                                   completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let deadline = Date().addingTimeInterval(timeout)
            var consecutive = 0
            while Date() < deadline {
                if AXIsProcessTrustedWithOptions(nil) {
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

    static func openInputMonitoringSettings() {
        openSettings(anchor: "Privacy_ListenEvent")
    }

    static func openAccessibilitySettings() {
        openSettings(anchor: "Privacy_Accessibility")
    }

    private static func openSettings(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
