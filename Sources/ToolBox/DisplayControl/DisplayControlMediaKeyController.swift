import AppKit
import Combine
import Foundation
import OSLog

private let mediaKeyEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<DisplayControlMediaKeyController>.fromOpaque(userInfo).takeUnretainedValue()
    return controller.handle(eventType: type, event: event)
}

private enum MediaKeyCode: Int {
    case soundUp = 0
    case soundDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7
    case contrastUp = 11
    case contrastDown = 12
}

private struct MediaKeyEvent {
    var code: MediaKeyCode
    var isPressed: Bool
    var isRepeat: Bool
}

final class DisplayControlMediaKeyController {
    private let service: DisplayControlService
    private let menuModel: DisplayControlMenuModel
    private let logger = Logger(subsystem: "ToolBox", category: "DisplayControlMediaKeys")
    private let lock = NSLock()
    private var cancellables = Set<AnyCancellable>()
    private var targetDisplayID: CGDirectDisplayID?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionPrompted = false
    private var wantsRunning = false

    @MainActor
    init(service: DisplayControlService, menuModel: DisplayControlMenuModel) {
        self.service = service
        self.menuModel = menuModel
    }

    @MainActor
    func start() {
        guard !wantsRunning else { return }
        wantsRunning = true

        Publishers.CombineLatest(menuModel.$selectedDisplayID, menuModel.$displayItems)
            .receive(on: RunLoop.main)
            .sink { [weak self] selectedDisplayID, items in
                self?.updateTarget(selectedDisplayID: selectedDisplayID, displayItems: items)
            }
            .store(in: &cancellables)

        updateTarget(selectedDisplayID: menuModel.selectedDisplayID, displayItems: menuModel.displayItems)
    }

    @MainActor
    func stop() {
        wantsRunning = false
        cancellables.removeAll()
        stopTap()
    }

    @MainActor
    private func updateTarget(selectedDisplayID: CGDirectDisplayID?, displayItems: [DisplayControlPickerItem]) {
        let nextTarget: CGDirectDisplayID? = {
            if let selectedDisplayID,
               let item = displayItems.first(where: { $0.id == selectedDisplayID }),
               item.isControllable {
                return selectedDisplayID
            }
            return displayItems.first(where: { $0.isControllable })?.id
        }()

        lock.lock()
        targetDisplayID = nextTarget
        let shouldRun = wantsRunning && nextTarget != nil
        lock.unlock()

        if shouldRun {
            startTapIfNeeded()
        } else {
            stopTap()
        }
    }

    @MainActor
    private func startTapIfNeeded() {
        guard eventTap == nil else { return }

        let mask = CGEventMask(1 << 14)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            if !permissionPrompted {
                permissionPrompted = true
                AppAlert.show(
                    title: "媒体键拦截未启用",
                    message: "需要开启输入监控权限后，才能拦截亮度和音量媒体键。",
                    primaryButton: ("打开系统设置", { Permissions.openInputMonitoringSettings() })
                )
            }
            logger.error("Failed to create media key event tap.")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    @MainActor
    private func stopTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
    }

    fileprivate func handle(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard eventType.rawValue == 14, let mediaKeyEvent = Self.parse(event: event) else {
            return Unmanaged.passUnretained(event)
        }

        lock.lock()
        let targetDisplayID = self.targetDisplayID
        lock.unlock()

        guard let targetDisplayID else {
            return Unmanaged.passUnretained(event)
        }

        guard mediaKeyEvent.isPressed else {
            return nil
        }

        DispatchQueue.main.async { [service] in
            switch mediaKeyEvent.code {
            case .brightnessUp:
                service.stepValue(displayID: targetDisplayID, kind: .brightness, delta: 0.05)
            case .brightnessDown:
                service.stepValue(displayID: targetDisplayID, kind: .brightness, delta: -0.05)
            case .soundUp:
                service.stepValue(displayID: targetDisplayID, kind: .volume, delta: 0.05)
            case .soundDown:
                service.stepValue(displayID: targetDisplayID, kind: .volume, delta: -0.05)
            case .mute:
                service.toggleMute(displayID: targetDisplayID)
            case .contrastUp:
                service.stepValue(displayID: targetDisplayID, kind: .contrast, delta: 0.05)
            case .contrastDown:
                service.stepValue(displayID: targetDisplayID, kind: .contrast, delta: -0.05)
            }
        }

        return nil
    }

    private static func parse(event: CGEvent) -> MediaKeyEvent? {
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.type == .systemDefined else {
            return nil
        }

        let data1 = nsEvent.data1
        let keyCode = Int((data1 & 0xFFFF0000) >> 16)
        let keyFlags = data1 & 0x0000FFFF
        let keyState = Int((keyFlags & 0xFF00) >> 8)
        let isRepeat = (keyFlags & 0x1) != 0
        guard let code = MediaKeyCode(rawValue: keyCode) else {
            return nil
        }
        return MediaKeyEvent(code: code, isPressed: keyState == 0xA, isRepeat: isRepeat)
    }
}
