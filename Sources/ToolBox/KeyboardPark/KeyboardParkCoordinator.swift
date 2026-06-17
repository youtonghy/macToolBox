import Foundation
import IOKit
import IOKit.hid
import Carbon.HIToolbox
import AppKit

/// F3 — 放键盘: disables ONLY the built-in keyboard by exclusively seizing (opening with
/// `kIOHIDOptionsTypeSeizeDevice`) each built-in keyboard's HID device. External keyboards
/// keep working, including the exit combo.
///
/// Exit: a Carbon global hotkey (⌃⌥⌘ + K) — registration requires a modifier+key combo, so a
/// single keypress can never trigger it. Since the built-in keyboard is seized, the combo is
/// typed on the external keyboard.
///
/// Safety: refuses to park if no external keyboard is detected, and auto-unparks after
/// 10 minutes as a backstop.
final class KeyboardParkCoordinator {

    private let exitKeyCode = UInt32(kVK_ANSI_K)
    private let exitMods: HotKeyController.Modifiers = [.control, .option, .command]
    private let autoUnparkSeconds: TimeInterval = 10 * 60

    private let hotKey = HotKeyController()
    private var seizedDevices: [IOHIDDevice] = []
    private var onAutoUnpark: (() -> Void)?
    private var autoUnparkTimer: Timer?

    /// Why parking was refused, surfaced to the user by the caller (AppDelegate).
    enum ParkError: Error {
        case inputMonitoringDenied   // IOHIDManagerOpen failed — Input Monitoring not granted
        case noExternalKeyboard      // safety: refuse to lock out with no way to unlock
        case seizeFailed             // kIOHIDOptionsTypeSeizeDevice open returned non-zero
    }

    /// Returns `.failure` with a reason if refused; `.success` once parked.
    @discardableResult
    func park(onAutoUnpark: @escaping () -> Void) -> Result<Void, ParkError> {
        guard seizedDevices.isEmpty else { return .success(()) } // already parked
        self.onAutoUnpark = onAutoUnpark

        let (manager, keyboards) = HIDDetector.enumerateKeyboards()
        let builtInCount = keyboards.filter { $0.isBuiltIn }.count
        NSLog("[ToolBox] park: manager=\(manager != nil) keyboards=\(keyboards.count) builtIn=\(builtInCount) external=\(keyboards.count - builtInCount)")
        guard let manager = manager else {
            // Input Monitoring denied.
            NSLog("[ToolBox] park: HID enumeration failed — Input Monitoring not granted?")
            Permissions.requestAccessibilityOnce()
            Permissions.openInputMonitoringSettings()
            self.onAutoUnpark = nil
            return .failure(.inputMonitoringDenied)
        }
        // We only needed the manager to enumerate. Close it before seizing so the
        // exclusive device open doesn't conflict with the manager's non-exclusive open.
        // The device refs stay valid (retained by `keyboards`).
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        let hasExternal = keyboards.contains { !$0.isBuiltIn }
        guard hasExternal else {
            // Safety: don't let the user lock themselves out with no external keyboard.
            NSLog("[ToolBox] park: refusing — no external keyboard detected")
            self.onAutoUnpark = nil
            return .failure(.noExternalKeyboard)
        }

        // Seize every built-in keyboard.
        var seized: [IOHIDDevice] = []
        for info in keyboards where info.isBuiltIn {
            let r = IOHIDDeviceOpen(info.device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            NSLog("[ToolBox] park: IOHIDDeviceOpen(seize) ret=\(r)")
            if r == 0 {
                seized.append(info.device)
            } else {
                // Seize failed: undo what we took and bail.
                NSLog("[ToolBox] park: seize failed (ret=\(r)) — aborting")
                for d in seized { IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) }
                self.onAutoUnpark = nil
                return .failure(.seizeFailed)
            }
        }
        seizedDevices = seized
        NSLog("[ToolBox] park: OK — seized \(seized.count) built-in keyboard(s)")

        // Register exit hotkey (only while parked).
        hotKey.install()
        hotKey.onTrigger = { [weak self] in self?.unpark(notify: true) }
        hotKey.register(keyCode: exitKeyCode, modifiers: exitMods)

        // Auto-unpark backstop.
        autoUnparkTimer = Timer.scheduledTimer(withTimeInterval: autoUnparkSeconds, repeats: false) { [weak self] _ in
            self?.unpark(notify: true)
        }
        return .success(())
    }

    /// Called from the toggle-off path (do not notify — UI is already flipping off).
    func unpark() { unpark(notify: false) }

    private func unpark(notify: Bool) {
        autoUnparkTimer?.invalidate(); autoUnparkTimer = nil
        hotKey.unregister()
        for d in seizedDevices { IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) }
        seizedDevices.removeAll()
        let cb = notify ? onAutoUnpark : nil
        onAutoUnpark = nil
        cb?()
    }

    deinit { unpark(notify: false) }
}
