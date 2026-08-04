import AppKit
import CoreGraphics
import OSLog

enum ShortcutMediaKey: Int, Equatable, Sendable {
    case soundUp = 0
    case soundDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7
    case contrastUp = 11
    case contrastDown = 12
}

struct ShortcutMediaKeyEvent: Equatable, Sendable {
    let key: ShortcutMediaKey
    let isPressed: Bool
    let isRepeat: Bool
}

enum ShortcutAction: Equatable, Sendable {
    case hotKey(ShortcutActionID)
    case mediaKey(ShortcutMediaKeyEvent)
}

@MainActor
protocol ShortcutMediaKeyRoutingBackend: AnyObject {
    var onEvent: ((ShortcutMediaKeyEvent) -> Bool)? { get set }
    var isActive: Bool { get }

    func start() -> Bool
    func stop()
    func canCreateListenOnlyTap() -> Bool
}

private let shortcutMediaKeyEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let backend = Unmanaged<LiveShortcutMediaKeyRoutingBackend>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    return MainActor.assumeIsolated {
        backend.handle(eventType: type, event: event)
    }
}

@MainActor
final class LiveShortcutMediaKeyRoutingBackend: ShortcutMediaKeyRoutingBackend {
    var onEvent: ((ShortcutMediaKeyEvent) -> Bool)?
    private(set) var isActive = false

    private let logger = Logger(subsystem: "ToolBox", category: "ShortcutMediaKeyRouting")
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() -> Bool {
        guard eventTap == nil else { return true }
        let mask = CGEventMask(1 << 14) // NSEvent.EventType.systemDefined
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: shortcutMediaKeyEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isActive = true
        return true
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isActive = false
    }

    func canCreateListenOnlyTap() -> Bool {
        let mask = CGEventMask(1 << 14)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) else {
            return false
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        return true
    }

    fileprivate func handle(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                logger.notice(
                    "Re-enabled shared media-key event tap after \(String(describing: eventType), privacy: .public)"
                )
            }
            return Unmanaged.passUnretained(event)
        }

        guard eventType.rawValue == 14,
              let mediaKeyEvent = Self.parse(event: event),
              onEvent?(mediaKeyEvent) == true else {
            return Unmanaged.passUnretained(event)
        }
        return nil
    }

    private static func parse(event: CGEvent) -> ShortcutMediaKeyEvent? {
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.type == .systemDefined else {
            return nil
        }
        let data1 = nsEvent.data1
        let keyCode = Int((data1 & 0xFFFF0000) >> 16)
        let keyFlags = data1 & 0x0000FFFF
        let keyState = Int((keyFlags & 0xFF00) >> 8)
        guard let key = ShortcutMediaKey(rawValue: keyCode) else { return nil }
        return ShortcutMediaKeyEvent(
            key: key,
            isPressed: keyState == 0xA,
            isRepeat: (keyFlags & 0x1) != 0
        )
    }

    deinit {
        onEvent = nil
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }
}
