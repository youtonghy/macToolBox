import AppKit
import Combine
import CoreGraphics
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

/// Intercepts Apple keyboard media keys (brightness / volume / mute / contrast)
/// and routes them to the selected external display via DDC.
///
/// Requires **Input Monitoring**. Creating a session event tap can still fail for
/// a short while after the user toggles the privacy switch — callers should retry
/// after the app becomes active again (returning from System Settings).
final class DisplayControlMediaKeyController: ObservableObject {
    private let service: DisplayControlService
    private let menuModel: DisplayControlMenuModel
    private let logger = Logger(subsystem: "ToolBox", category: "DisplayControlMediaKeys")
    private let lock = NSLock()
    private var cancellables = Set<AnyCancellable>()
    private var targetDisplayID: CGDirectDisplayID?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var wantsRunning = false
    private var hasRequestedPermission = false
    private var lastTapFailureAlertAt: Date?
    private var activationObserver: NSObjectProtocol?
    private var retryGeneration = 0

    /// Whether a live event tap is currently installed.
    @Published private(set) var isTapActive = false
    /// Latest Input Monitoring preflight status.
    @Published private(set) var inputMonitoringStatus: Permissions.InputMonitoringStatus = .unknown
    /// Human-readable status for Settings / diagnostics.
    @Published private(set) var statusText = "未启动"
    /// True when we want a tap but currently cannot install one.
    @Published private(set) var needsPermission = false

    @MainActor
    init(service: DisplayControlService, menuModel: DisplayControlMenuModel) {
        self.service = service
        self.menuModel = menuModel
        refreshPermissionStatus()
    }

    @MainActor
    func start() {
        guard !wantsRunning else { return }
        wantsRunning = true
        refreshPermissionStatus()

        Publishers.CombineLatest(menuModel.$selectedDisplayID, menuModel.$displayItems)
            .receive(on: RunLoop.main)
            .sink { [weak self] selectedDisplayID, items in
                self?.updateTarget(selectedDisplayID: selectedDisplayID, displayItems: items)
            }
            .store(in: &cancellables)

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleApplicationDidBecomeActive()
        }

        updateTarget(selectedDisplayID: menuModel.selectedDisplayID, displayItems: menuModel.displayItems)
    }

    @MainActor
    func stop() {
        wantsRunning = false
        cancellables.removeAll()
        retryGeneration += 1
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        stopTap()
        publishStatus(isActive: false, needsPermission: false, text: "已停止")
    }

    /// Re-check TCC and try to (re)install the media-key tap.
    /// Safe to call from Settings after the user toggles the privacy switch.
    @MainActor
    func refreshAndRetry(promptIfNeeded: Bool = false) {
        refreshPermissionStatus()
        if promptIfNeeded, !Permissions.isInputMonitoringTrusted {
            Permissions.requestInputMonitoring()
            refreshPermissionStatus()
        }
        restartTapIfNeeded(force: true)
    }

    @MainActor
    func openInputMonitoringSettings() {
        Permissions.openInputMonitoringSettings()
        // After the user returns from Settings, didBecomeActive will retry.
        // Also schedule a few delayed retries in case activation is noisy.
        scheduleDeferredRetries()
    }

    @MainActor
    private func handleApplicationDidBecomeActive() {
        refreshPermissionStatus()
        guard wantsRunning else { return }
        restartTapIfNeeded(force: eventTap == nil)
    }

    @MainActor
    private func updateTarget(
        selectedDisplayID: CGDirectDisplayID?,
        displayItems: [DisplayControlPickerItem]
    ) {
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
            startTapIfNeeded(force: false)
        } else {
            stopTap()
            if wantsRunning {
                publishStatus(
                    isActive: false,
                    needsPermission: false,
                    text: nextTarget == nil ? "等待可控制的外接显示器" : "未启动"
                )
            }
        }
    }

    @MainActor
    private func restartTapIfNeeded(force: Bool) {
        lock.lock()
        let shouldRun = wantsRunning && targetDisplayID != nil
        lock.unlock()

        guard shouldRun else {
            stopTap()
            return
        }
        startTapIfNeeded(force: force)
    }

    @MainActor
    private func startTapIfNeeded(force: Bool) {
        if force {
            stopTap()
        }

        lock.lock()
        let alreadyInstalled = eventTap != nil
        lock.unlock()
        if alreadyInstalled {
            publishStatus(isActive: true, needsPermission: false, text: "媒体键已接管")
            return
        }

        refreshPermissionStatus()

        // Surface the app in the Input Monitoring list before the first tap attempt.
        if !Permissions.isInputMonitoringTrusted, !hasRequestedPermission {
            hasRequestedPermission = true
            Permissions.requestInputMonitoring()
            refreshPermissionStatus()
        }

        let mask = CGEventMask(1 << 14) // NSEvent.EventType.systemDefined
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            let trusted = Permissions.isInputMonitoringTrusted
            publishStatus(
                isActive: false,
                needsPermission: true,
                text: trusted
                    ? "权限已开，但仍无法建立事件监听（可尝试重启 ToolBox）"
                    : "需要输入监控权限"
            )
            logger.error(
                "Failed to create media key event tap. inputMonitoring=\(String(describing: self.inputMonitoringStatus), privacy: .public)"
            )
            presentPermissionAlertIfNeeded()
            scheduleDeferredRetries()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        lock.lock()
        eventTap = tap
        runLoopSource = source
        lock.unlock()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        publishStatus(isActive: true, needsPermission: false, text: "媒体键已接管")
        retryGeneration += 1
        logger.info("Media key event tap installed.")
    }

    @MainActor
    private func stopTap() {
        lock.lock()
        let tap = eventTap
        let source = runLoopSource
        eventTap = nil
        runLoopSource = nil
        lock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if isTapActive {
            isTapActive = false
        }
    }

    @MainActor
    private func presentPermissionAlertIfNeeded() {
        // Avoid spamming: at most once every 90s while the condition persists.
        let now = Date()
        if let lastTapFailureAlertAt, now.timeIntervalSince(lastTapFailureAlertAt) < 90 {
            return
        }
        lastTapFailureAlertAt = now

        let message: String
        if Permissions.isInputMonitoringTrusted {
            message = """
            系统显示已授予输入监控，但当前进程仍无法创建媒体键事件监听。

            常见原因：
            1. 刚打开开关后，需要完全退出并重新打开 ToolBox；
            2. 调试版 / 不同路径的 ToolBox 在列表里有多条记录，请确认开关开在当前正在运行的那一项；
            3. 签名变化会导致权限失效，请删除旧条目后重新授权。
            """
        } else {
            message = "需要开启「输入监控」权限后，才能拦截亮度 / 音量媒体键并转发给外接显示器。"
        }

        AppAlert.show(
            title: "媒体键拦截未启用",
            message: message,
            primaryButton: ("打开系统设置", { [weak self] in
                self?.openInputMonitoringSettings()
            })
        )
    }

    @MainActor
    private func scheduleDeferredRetries() {
        retryGeneration += 1
        let generation = retryGeneration

        // Returning from System Settings is racy: TCC can lag a few seconds after
        // the toggle flips, and some builds only take effect after process restart.
        let delays: [TimeInterval] = [1.0, 2.5, 5.0, 10.0]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                guard self.retryGeneration == generation else { return }
                guard self.wantsRunning, self.eventTap == nil else { return }
                self.refreshPermissionStatus()
                self.restartTapIfNeeded(force: true)
            }
        }
    }

    @MainActor
    private func refreshPermissionStatus() {
        let status = Permissions.inputMonitoringStatus
        if inputMonitoringStatus != status {
            inputMonitoringStatus = status
        }
    }

    @MainActor
    private func publishStatus(isActive: Bool, needsPermission: Bool, text: String) {
        if isTapActive != isActive {
            isTapActive = isActive
        }
        if self.needsPermission != needsPermission {
            self.needsPermission = needsPermission
        }
        if statusText != text {
            statusText = text
        }
    }

    fileprivate func handle(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // System can silently disable taps under load; always re-enable.
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            lock.lock()
            let tap = eventTap
            lock.unlock()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                logger.notice("Re-enabled media key event tap after \(String(describing: eventType), privacy: .public).")
            }
            return Unmanaged.passUnretained(event)
        }

        guard eventType.rawValue == 14, let mediaKeyEvent = Self.parse(event: event) else {
            return Unmanaged.passUnretained(event)
        }

        lock.lock()
        let targetDisplayID = self.targetDisplayID
        lock.unlock()

        guard let targetDisplayID else {
            return Unmanaged.passUnretained(event)
        }

        // Swallow key-up and key-down so the system does not also drive the built-in panel.
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
