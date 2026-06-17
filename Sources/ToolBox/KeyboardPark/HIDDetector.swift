import Foundation
import IOKit
import IOKit.hid

// HID matching-dictionary keys. These are plain C `#define` string macros in IOHIDKeys.h
// (DeviceUsagePage / DeviceUsage / "Built-In" / "Transport") — used here as literals.
private let kUsagePage = "DeviceUsagePage"
private let kUsage     = "DeviceUsage"
private let kBuiltIn   = "Built-In"
private let kTransport = "Transport"
private let kProduct   = "Product"

/// Enumerates keyboard HID devices and classifies built-in vs external.
enum HIDDetector {

    struct KeyboardInfo {
        let device: IOHIDDevice
        let isBuiltIn: Bool
    }

    /// Enumerates all keyboards (built-in + external).
    /// Returns `manager = nil` if Input Monitoring permission is denied (open fails).
    /// The caller owns the returned manager (close it when done); device refs are retained
    /// by the returned array.
    static func enumerateKeyboards() -> (manager: IOHIDManager?, keyboards: [KeyboardInfo]) {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // Device-level keyboard matching. The previous single match used the keyboard scan-code
        // page 0x07 / usage 0x06 — that is NOT a device usage, so external keyboards (whose
        // primary usage is Generic Desktop / Keyboard = page 0x01 usage 0x06) were never matched.
        // Match both the standard device usage and the whole keyboard/keypad page so every
        // keyboard (built-in and external) is enumerated. SetDeviceMatchingMultiple matches a
        // device satisfying ANY entry, and dedupes.
        let matches: [[String: Any]] = [
            [kUsagePage: 0x01, kUsage: 0x06],   // Generic Desktop / Keyboard (standard, incl. external USB/BT)
            [kUsagePage: 0x07],                  // any Keyboard/Keypad-page device (Apple internal quirk)
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        if IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) != 0 {
            // kIOReturnNotPermitted etc. -> Input Monitoring denied.
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return (nil, [])
        }

        guard let deviceSet = IOHIDManagerCopyDevices(manager) else { return (manager, []) }
        let devices = (deviceSet as NSSet).allObjects as? [IOHIDDevice] ?? []
        let infos = devices.map { d -> KeyboardInfo in
            let built = isBuiltIn(d)
            let product = (IOHIDDeviceGetProperty(d, kProduct as CFString) as? String) ?? "?"
            NSLog("[ToolBox] HID keyboard: \(product) BuiltIn=\(String(describing: IOHIDDeviceGetProperty(d, kBuiltIn as CFString))) Transport=\(String(describing: IOHIDDeviceGetProperty(d, kTransport as CFString))) -> classified builtIn=\(built)")
            return KeyboardInfo(device: d, isBuiltIn: built)
        }
        return (manager, infos)
    }

    /// True if the device is the Mac's built-in keyboard.
    /// Prefers the explicit "Built-In" property, falls back to the transport type
    /// (external keyboards report USB / Bluetooth), and defaults to `false` for unknowns
    /// so we never accidentally seize an external/unknown device.
    private static func isBuiltIn(_ device: IOHIDDevice) -> Bool {
        if let n = IOHIDDeviceGetProperty(device, kBuiltIn as CFString) as? NSNumber {
            return n.boolValue || n.intValue != 0
        }
        if let transport = IOHIDDeviceGetProperty(device, kTransport as CFString) as? String {
            let t = transport.lowercased()
            return !(t.contains("usb") || t.contains("bluetooth") || t == "bt")
        }
        return false
    }
}
