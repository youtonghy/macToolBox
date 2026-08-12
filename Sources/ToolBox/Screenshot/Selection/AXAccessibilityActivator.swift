import ApplicationServices
import CoreGraphics
import Foundation

/// Records which accessibility opt-in attributes this process turned on for a
/// given application, so they can be restored when the capture session ends.
struct AXActivationRecord: Equatable, Sendable {
    var setManualAccessibility: Bool
    var setEnhancedUserInterface: Bool

    var isEmpty: Bool { !setManualAccessibility && !setEnhancedUserInterface }
}

/// Many applications do not expose their full accessibility tree by default:
///
/// - AppKit apps build deep AX subtrees lazily; without `AXEnhancedUserInterface`
///   a hit test frequently resolves only to the window itself.
/// - Electron/Chromium apps (VS Code, Chrome, WeChat) keep their AX tree switched
///   off entirely until `AXManualAccessibility` is set.
///
/// System processes (menu bar, Dock) are always fully exposed, which is why they
/// resolve correctly without any opt-in.
///
/// This type turns those attributes on for a target application, remembers only
/// the flags it actually changed, and can restore them afterwards. Attributes that
/// were already enabled by another client are never touched, so we do not disable
/// accessibility for screen readers or other assistive software.
///
/// Not `@MainActor`: intended to be called from the same background queue that
/// performs the AX hit test, so an unresponsive target cannot stall the UI.
final class AXAccessibilityActivator: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [pid_t: AXActivationRecord] = [:]
    private let setAttribute: @Sendable (AXUIElement, String, Bool) -> Bool
    private let readAttribute: @Sendable (AXUIElement, String) -> Bool?

    init(
        setAttribute: (@Sendable (AXUIElement, String, Bool) -> Bool)? = nil,
        readAttribute: (@Sendable (AXUIElement, String) -> Bool?)? = nil
    ) {
        self.setAttribute = setAttribute ?? { element, name, value in
            AXUIElementSetAttributeValue(
                element,
                name as CFString,
                (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
            ) == .success
        }
        self.readAttribute = readAttribute ?? { element, name in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
                  let raw = value else { return nil }
            guard CFGetTypeID(raw) == CFBooleanGetTypeID() else { return nil }
            return CFBooleanGetValue((raw as! CFBoolean))
        }
    }

    static let manualAccessibilityAttribute = "AXManualAccessibility"
    static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"

    /// Enable the accessibility opt-in attributes for `application`, unless this
    /// process has already done so for `pid`.
    ///
    /// Returns the flags newly enabled by this call. An empty record means the
    /// application already exposed its tree (or the attributes are unsupported),
    /// which is a normal, non-error outcome.
    @discardableResult
    func activate(application: AXUIElement, pid: pid_t) -> AXActivationRecord {
        lock.lock()
        let alreadyActivated = records[pid] != nil
        lock.unlock()
        if alreadyActivated { return .init(setManualAccessibility: false, setEnhancedUserInterface: false) }

        var record = AXActivationRecord(setManualAccessibility: false, setEnhancedUserInterface: false)
        // Only flip an attribute that is readable and currently false. If the
        // attribute is absent the app does not support it; if it is already true
        // another client owns it and we must not claim or later clear it.
        if readAttribute(application, Self.manualAccessibilityAttribute) == false,
           setAttribute(application, Self.manualAccessibilityAttribute, true) {
            record.setManualAccessibility = true
        }
        if readAttribute(application, Self.enhancedUserInterfaceAttribute) == false,
           setAttribute(application, Self.enhancedUserInterfaceAttribute, true) {
            record.setEnhancedUserInterface = true
        }

        lock.lock()
        records[pid] = record
        lock.unlock()
        return record
    }

    /// Restore every attribute this process turned on, and forget all bookkeeping.
    /// Safe to call more than once; the second call is a no-op.
    func restoreAll(applicationForPID: (pid_t) -> AXUIElement?) {
        lock.lock()
        let pending = records
        records.removeAll()
        lock.unlock()

        for (pid, record) in pending where !record.isEmpty {
            guard let application = applicationForPID(pid) else { continue }
            if record.setManualAccessibility {
                _ = setAttribute(application, Self.manualAccessibilityAttribute, false)
            }
            if record.setEnhancedUserInterface {
                _ = setAttribute(application, Self.enhancedUserInterfaceAttribute, false)
            }
        }
    }

    /// Test seam: the flags currently believed to be owned by this process.
    func record(for pid: pid_t) -> AXActivationRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records[pid]
    }
}
