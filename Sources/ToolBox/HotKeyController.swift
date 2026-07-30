import Carbon.HIToolbox
import AppKit

private final class HotKeyCallbackContext {
    var onTrigger: (() -> Void)?
}

private let hotKeyEventHandler: EventHandlerUPP = { _, _, context in
    guard let context else { return OSStatus(eventNotHandledErr) }
    let callbackContext = Unmanaged<HotKeyCallbackContext>
        .fromOpaque(context)
        .takeUnretainedValue()
    callbackContext.onTrigger?()
    return noErr
}

struct HotKeySystem {
    let installHandler: (
        _ context: UnsafeMutableRawPointer,
        _ output: UnsafeMutablePointer<EventHandlerRef?>
    ) -> OSStatus
    let removeHandler: (EventHandlerRef) -> OSStatus
    let registerHotKey: (
        _ keyCode: UInt32,
        _ modifiers: UInt32,
        _ hotKeyID: EventHotKeyID,
        _ output: UnsafeMutablePointer<EventHotKeyRef?>
    ) -> OSStatus
    let unregisterHotKey: (EventHotKeyRef) -> OSStatus

    static let live = HotKeySystem(
        installHandler: { context, output in
            var spec = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            return InstallEventHandler(
                GetApplicationEventTarget(),
                hotKeyEventHandler,
                1,
                &spec,
                context,
                output
            )
        },
        removeHandler: RemoveEventHandler,
        registerHotKey: { keyCode, modifiers, hotKeyID, output in
            RegisterEventHotKey(
                keyCode,
                modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                output
            )
        },
        unregisterHotKey: UnregisterEventHotKey
    )
}

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
    private var retainedCallbackContext: Unmanaged<HotKeyCallbackContext>?
    private let callbackContext = HotKeyCallbackContext()
    private let system: HotKeySystem
    private let signature: OSType = 0x484F544B // 'HOTK'
    private let id: UInt32 = 1

    /// Closure invoked (on the main thread) when the combo is pressed.
    var onTrigger: (() -> Void)? {
        get { callbackContext.onTrigger }
        set { callbackContext.onTrigger = newValue }
    }

    init(system: HotKeySystem = .live) {
        self.system = system
    }

    @discardableResult
    func install() -> Bool {
        guard handlerRef == nil else { return true }

        let retainedContext = Unmanaged.passRetained(callbackContext)
        var installedHandler: EventHandlerRef?
        let status = system.installHandler(retainedContext.toOpaque(), &installedHandler)
        guard status == noErr, let installedHandler else {
            retainedContext.release()
            return false
        }

        handlerRef = installedHandler
        retainedCallbackContext = retainedContext
        return true
    }

    /// keyCode: virtual keycode (e.g. `UInt32(kVK_ANSI_K)`). modifiers: Carbon bits.
    @discardableResult
    func register(keyCode: UInt32, modifiers: Modifiers) -> Bool {
        guard handlerRef != nil else { return false }
        guard unregister() else { return false }
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var registeredHotKey: EventHotKeyRef?
        let status = system.registerHotKey(
            keyCode,
            modifiers.rawValue,
            hotKeyID,
            &registeredHotKey
        )
        guard status == noErr, let registeredHotKey else { return false }
        hotKeyRef = registeredHotKey
        return true
    }

    @discardableResult
    func unregister() -> Bool {
        guard let hotKeyRef else { return true }
        guard system.unregisterHotKey(hotKeyRef) == noErr else { return false }
        self.hotKeyRef = nil
        return true
    }

    private func removeHandler() -> Bool {
        guard let handlerRef else { return true }
        let status = system.removeHandler(handlerRef)
        self.handlerRef = nil
        if status == noErr {
            retainedCallbackContext?.release()
        }
        // Carbon may still call the handler after a failed removal. Leak the retained
        // context deliberately rather than release memory that the callback can reference.
        retainedCallbackContext = nil
        return status == noErr
    }

    deinit {
        callbackContext.onTrigger = nil
        _ = unregister()
        _ = removeHandler()
    }
}
