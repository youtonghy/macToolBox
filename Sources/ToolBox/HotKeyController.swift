import Carbon.HIToolbox
import AppKit

/// Wraps a single Carbon global hotkey (`RegisterEventHotKey`).
/// Fire-only (key-down). Requires NO TCC permission. Because registration requires a
/// modifier+key combination, a lone keypress can never trigger it.
final class HotKeyController {

    /// Carbon modifier bit combination.
    struct Modifiers: OptionSet {
        let rawValue: UInt32
        static let command   = Modifiers(rawValue: UInt32(cmdKey))
        static let option    = Modifiers(rawValue: UInt32(optionKey))
        static let control   = Modifiers(rawValue: UInt32(controlKey))
        static let shift     = Modifiers(rawValue: UInt32(shiftKey))
    }

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x484F544B // 'HOTK'
    private let id: UInt32 = 1
    private var installed = false

    /// Closure invoked (on the main thread) when the combo is pressed.
    var onTrigger: (() -> Void)?

    func install() {
        guard !installed else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let handler: @convention(c) (EventHandlerCallRef?, EventRef?, UnsafeMutableRawPointer?) -> OSStatus = { _, _, ctx in
            guard let ctx else { return noErr }
            let me = Unmanaged<HotKeyController>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.onTrigger?() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        installed = true
    }

    /// keyCode: virtual keycode (e.g. `UInt32(kVK_ANSI_K)`). modifiers: Carbon bits.
    func register(keyCode: UInt32, modifiers: Modifiers) {
        unregister()
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers.rawValue, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { hotKeyRef = nil }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    deinit { unregister() }
}
