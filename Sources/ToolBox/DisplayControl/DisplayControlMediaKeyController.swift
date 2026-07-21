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
/// Uses a **default** (modifying) session event tap so media keys can be swallowed
/// instead of also driving the built-in panel. On current macOS that usually needs:
/// - Input Monitoring
/// - Accessibility
///
/// TCC can lag after the user flips a privacy switch. Retry when the application
/// becomes active again instead of polling TCC continuously in the background.
final class DisplayControlMediaKeyController: ObservableObject {
    private static let permissionAlertShownKey = "display.mediaKeys.permissionAlertShown.v2"

    private let service: DisplayControlService
    private let menuModel: DisplayControlMenuModel
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "ToolBox", category: "DisplayControlMediaKeys")
    private let lock = NSLock()
    private var cancellables = Set<AnyCancellable>()
    private var targetDisplayID: CGDirectDisplayID?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var wantsRunning = false
    private var hasRegisteredForPermission = false
    private var activationObserver: NSObjectProtocol?
    private var lastLoggedFailureSignature: String?

    @Published private(set) var isTapActive = false
    @Published private(set) var inputMonitoringStatus: Permissions.InputMonitoringStatus = .unknown
    @Published private(set) var isAccessibilityTrusted = false
    @Published private(set) var permissionGap: Permissions.MediaKeyPermissionGap = .both
    @Published private(set) var statusText = "未启动"
    @Published private(set) var needsPermission = false

    /// Effective labels for Settings: prefer operational success over flaky TCC preflight.
    /// A live `.defaultTap` means media keys are usable even if CG/IOHID preflight still says denied.
    var accessibilityStatusLabel: String {
        if isTapActive || isAccessibilityTrusted { return "已授权" }
        return "未授权"
    }

    var inputMonitoringStatusLabel: String {
        if isTapActive { return "已可用" }
        return inputMonitoringStatus.label
    }

    var accessibilityLooksGranted: Bool {
        isTapActive || isAccessibilityTrusted
    }

    var inputMonitoringLooksGranted: Bool {
        isTapActive || inputMonitoringStatus == .granted
    }

    @MainActor
    init(
        service: DisplayControlService,
        menuModel: DisplayControlMenuModel,
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.menuModel = menuModel
        self.defaults = defaults
        refreshPermissionStatus(probeTaps: false)
    }

    @MainActor
    func start() {
        guard !wantsRunning else { return }
        wantsRunning = true
        refreshPermissionStatus(probeTaps: false)

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
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        stopTap()
        publishStatus(isActive: false, needsPermission: false, text: "已停止")
    }

    /// Re-check TCC and try to (re)install the media-key tap.
    @MainActor
    func refreshAndRetry(promptIfNeeded: Bool = false) {
        refreshPermissionStatus(probeTaps: true)
        if promptIfNeeded {
            quietlyRegisterMissingPermissions(promptAccessibility: false)
            refreshPermissionStatus(probeTaps: false)
        }
        restartTapIfNeeded(force: true)
    }

    /// Registers ToolBox for the missing privacy service(s), then opens the
    /// relevant System Settings pane so the user only flips a switch.
    @MainActor
    func openRequiredPermissionSettings() {
        refreshPermissionStatus(probeTaps: true)
        Permissions.openMediaKeyPermissionSettings(gap: permissionGap)
    }

    /// Back-compat alias used by older call sites / Settings buttons.
    @MainActor
    func openInputMonitoringSettings() {
        openRequiredPermissionSettings()
    }

    @MainActor
    private func handleApplicationDidBecomeActive() {
        refreshPermissionStatus(probeTaps: false)
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
            permissionGap = .none
            publishStatus(isActive: true, needsPermission: false, text: "媒体键已接管")
            return
        }

        refreshPermissionStatus(probeTaps: false)

        if !hasRegisteredForPermission {
            hasRegisteredForPermission = true
            quietlyRegisterMissingPermissions(promptAccessibility: false)
            refreshPermissionStatus(probeTaps: false)
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
            let listenOnlyWorks = canCreateProbeTap(options: .listenOnly, mask: mask)
            let gap = Permissions.mediaKeyPermissionGap(
                canCreateListenOnlyTap: listenOnlyWorks,
                canCreateDefaultTap: false
            )
            let nextStatusText = statusText(for: gap)
            permissionGap = gap
            publishStatus(
                isActive: false,
                needsPermission: true,
                text: nextStatusText
            )
            let signature = "\(gap)|\(inputMonitoringStatus)|\(isAccessibilityTrusted)|\(listenOnlyWorks)"
            if lastLoggedFailureSignature != signature {
                lastLoggedFailureSignature = signature
                logger.error(
                    "Failed to create media key event tap. gap=\(String(describing: gap), privacy: .public) im=\(String(describing: self.inputMonitoringStatus), privacy: .public) ax=\(self.isAccessibilityTrusted, privacy: .public) listenOnly=\(listenOnlyWorks, privacy: .public)"
                )
            }
            presentPermissionAlertIfNeeded(gap: gap)
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        lock.lock()
        eventTap = tap
        runLoopSource = source
        lock.unlock()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        permissionGap = .none
        lastLoggedFailureSignature = nil
        publishStatus(isActive: true, needsPermission: false, text: "媒体键已接管")
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

    /// Creates a temporary tap solely to probe whether TCC allows that option.
    private func canCreateProbeTap(options: CGEventTapOptions, mask: CGEventMask) -> Bool {
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: options,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) else {
            return false
        }
        // Immediately tear down — we only needed the create result.
        CGEvent.tapEnable(tap: tap, enable: false)
        return true
    }

    @MainActor
    private func quietlyRegisterMissingPermissions(promptAccessibility: Bool) {
        if !Permissions.isInputMonitoringTrusted {
            Permissions.registerInputMonitoring()
        }
        if !Permissions.isAccessibilityTrusted {
            Permissions.registerAccessibility(prompt: promptAccessibility)
        }
    }

    @MainActor
    private func presentPermissionAlertIfNeeded(gap: Permissions.MediaKeyPermissionGap) {
        if defaults.bool(forKey: Self.permissionAlertShownKey) {
            return
        }
        defaults.set(true, forKey: Self.permissionAlertShownKey)

        let message: String
        switch gap {
        case .accessibility:
            message = """
            媒体键拦截需要「辅助功能」权限（用于吞掉系统媒体键，避免内置屏也被调节）。

            点击「打开系统设置」后，系统会自动列出 ToolBox，你只需打开开关。授权后本应用会自动重新检测。
            """
        case .inputMonitoring:
            message = """
            媒体键拦截需要「输入监控」权限。

            点击「打开系统设置」后，系统会自动列出 ToolBox，你只需打开开关。授权后本应用会自动重新检测。
            """
        case .both:
            message = """
            媒体键拦截需要「辅助功能」与「输入监控」权限。

            点击「打开系统设置」后，请打开列表中的 ToolBox 开关。授权后本应用会自动重新检测。
            """
        case .restartRequired:
            message = """
            系统显示相关权限已开启，但当前进程仍无法创建媒体键事件监听。

            请完全退出并重新打开 ToolBox。若列表里有多条调试版记录，只保留并开启当前正在运行的那一项。
            """
        case .none:
            return
        }

        AppAlert.show(
            title: "媒体键拦截未启用",
            message: message,
            primaryButton: ("打开系统设置", { [weak self] in
                self?.openRequiredPermissionSettings()
            })
        )
    }

    @MainActor
    private func refreshPermissionStatus(probeTaps: Bool) {
        let im = Permissions.inputMonitoringStatus
        let ax = Permissions.isAccessibilityTrusted
        if inputMonitoringStatus != im {
            inputMonitoringStatus = im
        }
        if isAccessibilityTrusted != ax {
            isAccessibilityTrusted = ax
        }

        if probeTaps, eventTap == nil {
            let mask = CGEventMask(1 << 14)
            let listenOnly = canCreateProbeTap(options: .listenOnly, mask: mask)
            let defaultTap = canCreateProbeTap(options: .defaultTap, mask: mask)
            let gap = Permissions.mediaKeyPermissionGap(
                canCreateListenOnlyTap: listenOnly,
                canCreateDefaultTap: defaultTap
            )
            if permissionGap != gap {
                permissionGap = gap
            }
        } else if eventTap != nil {
            if permissionGap != .none {
                permissionGap = .none
            }
        } else {
            let gap = Permissions.mediaKeyPermissionGap(
                canCreateListenOnlyTap: nil,
                canCreateDefaultTap: false
            )
            if permissionGap != gap {
                permissionGap = gap
            }
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

    private func statusText(for gap: Permissions.MediaKeyPermissionGap) -> String {
        switch gap {
        case .none:
            return "媒体键已接管"
        case .accessibility:
            return "需要辅助功能权限"
        case .inputMonitoring:
            return "需要输入监控权限"
        case .both:
            return "需要辅助功能与输入监控权限"
        case .restartRequired:
            return "权限已开，请完全退出后重开 ToolBox"
        }
    }

    fileprivate func handle(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
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
