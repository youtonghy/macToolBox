import AppKit
import CoreMedia
import OSLog
import ScreenCaptureKit

// AppKit must not constrain this borderless overlay onto the main display.
private final class DuoOverlayPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Live desktop capture + glass overlay driven by the lid-angle sensor.
/// Capture and render are local only. No recordings or network output.
/// Ported from https://github.com/jlxc2001/MacBook-Duo (GlobalDesktopController);
/// the status item, dedicated hotkeys and the permission-reset helper are
/// handled by ToolBox's own settings / shortcut infrastructure instead.
@MainActor
final class DuoEffectCoordinator: NSObject, @preconcurrency SCStreamOutput, SCStreamDelegate {
    private let model: DuoEffectModel
    /// Invoked when a user-initiated start fails so the settings toggle can switch back off.
    var onFailure: () -> Void = {}

    private var overlay: NSWindow?
    private var renderer: DuoGlassMetalView?
    private var stream: SCStream?
    private var timer: Timer?
    private var generation = 0
    private var starting = false
    private var startedAt = Date()
    private var captureFPS: Int32 = 30
    private var updatingCaptureRate = false
    private var receivedFrame = false
    private var requestedVisible = false
    private var previewUntil = Date.distantPast
    private var previewRequested = false
    private var previewOnly = false
    private var capturedDisplayID: CGDirectDisplayID?
    private var statusTick = 0
    private var observers: [NSObjectProtocol] = []
    private var resumeWanted = false
    private var sleepReasons = Set<String>()
    private var recoveryTimer: Timer?
    private var recoveryFailures = 0
    private var nextRecoveryAttempt = Date.distantPast
    // A start failure survives the follow-up stop() call (triggered when the
    // settings toggle flips back off) so the reason stays visible in settings.
    private var failureStatus: String?
    // Our own SCApplication stays valid while our windows are hidden, so the
    // overlay itself never shows up in the captured desktop.
    private var captureApplication: SCRunningApplication?
    private let logger = Logger(subsystem: "ToolBox", category: "DuoEffect")

    init(model: DuoEffectModel) {
        self.model = model
        super.init()
        registerObservers()
    }

    deinit {
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        timer?.invalidate()
        recoveryTimer?.invalidate()
    }

    private func registerObservers() {
        // Session activation notifications alone do not cover ordinary screen locking.
        for (name, locked) in [("com.apple.screenIsLocked", true),
                               ("com.apple.screenIsUnlocked", false)] {
            observers.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if locked {
                        self.sleepReasons.insert("lock")
                        self.suspend(reason: "屏幕已锁定，解锁后自动恢复")
                    } else {
                        self.sleepReasons.remove("lock")
                        self.recoveryFailures = 0
                        self.nextRecoveryAttempt = .distantPast
                        self.recoverIfReady()
                    }
                }
            })
        }
        for (name, key) in [(NSWorkspace.willSleepNotification, "system"),
                            (NSWorkspace.screensDidSleepNotification, "display"),
                            (NSWorkspace.sessionDidResignActiveNotification, "session")] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.sleepReasons.insert(key)
                        self?.suspend(reason: "已暂停，开盖唤醒后自动恢复")
                    }
                })
        }
        for (name, key) in [(NSWorkspace.didWakeNotification, "system"),
                            (NSWorkspace.screensDidWakeNotification, "display"),
                            (NSWorkspace.sessionDidBecomeActiveNotification, "session")] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.sleepReasons.remove(key)
                        self?.recoverIfReady()
                    }
                })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Retain the texture across Space changes; sleep/session guards
            // prevent the desktop overlay from being drawn over a locked session.
            MainActor.assumeIsolated {
                self?.overlay?.orderOut(nil)
                self?.startedAt = Date()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenConfigurationChanged()
            }
        })
    }

    func start() {
        start(automatically: false)
    }

    /// An 8-second live preview that does not require physically moving the lid.
    func preview() {
        previewRequested = true
        if stream != nil || starting {
            previewUntil = Date().addingTimeInterval(8)
            return
        }
        previewOnly = true
        start(automatically: false)
    }

    func stop(reason: String, preserveIntent: Bool = false) {
        if !preserveIntent {
            resumeWanted = false
            recoveryTimer?.invalidate()
            recoveryTimer = nil
        }
        generation += 1
        starting = false
        overlay?.orderOut(nil)
        overlay = nil
        renderer = nil
        capturedDisplayID = nil
        timer?.invalidate()
        timer = nil
        let oldStream = stream
        stream = nil
        if let oldStream { Task { try? await oldStream.stopCapture() } }
        receivedFrame = false
        requestedVisible = false
        previewRequested = false
        previewOnly = false
        previewUntil = .distantPast
        model.setActive(resumeWanted)
        model.statusText = failureStatus ?? reason
        logger.info("Duo effect stopped: \(reason, privacy: .public)")
    }

    // Menu/Dock visibility also posts screen-parameter notifications.
    // Only stop for a real change to the captured display or its full frame.
    func screenConfigurationChanged() {
        guard let id = capturedDisplayID, let overlay else { return }
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        if screen == nil || screen!.frame != overlay.frame {
            overlay.orderOut(nil)
            generation += 1
            starting = false
            let oldStream = stream
            stream = nil
            receivedFrame = false
            if let oldStream { Task { try? await oldStream.stopCapture() } }
            if let screen {
                overlay.setFrame(screen.frame, display: false)
            }
            suspend(reason: "内建显示器变化，等待恢复实时效果")
        }
    }

    private func start(automatically: Bool) {
        if stream != nil || starting {
            // Already capturing (e.g. a preview): keep the stream and become persistent.
            resumeWanted = true
            model.setActive(true)
            if !automatically {
                previewOnly = false
                previewRequested = false
                previewUntil = .distantPast
            }
            recoverIfReady()
            return
        }
        if !automatically {
            recoveryFailures = 0
            nextRecoveryAttempt = .distantPast
        }
        failureStatus = nil
        resumeWanted = true
        model.setActive(true)
        guard sleepReasons.isEmpty else {
            suspend(reason: "等待屏幕唤醒后自动恢复")
            return
        }
        guard model.sensor.isSupported else {
            resumeWanted = false
            model.setActive(false)
            failureStatus = "未找到兼容的铰链传感器"
            model.statusText = failureStatus!
            if !automatically { onFailure() }
            return
        }
        model.sensor.start()
        starting = true
        generation += 1
        let token = generation
        model.statusText = "正在请求桌面捕获…"
        if !automatically {
            // User-initiated start: surface the system prompt once if needed.
            _ = Permissions.requestScreenCapture()
        }
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard token == generation else { return }
                // Target the built-in panel. External displays aren't hinge-driven.
                guard let display = content.displays.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }),
                      let screen = NSScreen.screens.first(where: {
                          ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
                      }) else { throw DuoError.noInternalDisplay }
                let ownPID = ProcessInfo.processInfo.processIdentifier
                if let application = content.applications.first(where: { $0.processID == ownPID }) {
                    captureApplication = application
                }
                guard let application = captureApplication, application.processID == ownPID else {
                    throw DuoError.cannotExcludeSelf
                }
                let filter = SCContentFilter(display: display, excludingApplications: [application], exceptingWindows: [])
                let config = SCStreamConfiguration()
                // Logical resolution keeps the power budget small.
                config.width = Int(screen.frame.width)
                config.height = Int(screen.frame.height)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.queueDepth = 3
                config.showsCursor = false
                config.capturesAudio = false
                let renderer = self.renderer ?? DuoGlassMetalView()
                guard renderer.device != nil else { throw DuoError.noGPU }
                let overlay = (self.overlay as? DuoOverlayPanel) ?? DuoOverlayPanel(
                    contentRect: screen.frame,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false,
                    screen: screen
                )
                overlay.hidesOnDeactivate = false
                overlay.becomesKeyOnlyIfNeeded = true
                overlay.isReleasedWhenClosed = false
                overlay.backgroundColor = .black
                overlay.hasShadow = false
                overlay.ignoresMouseEvents = true
                // A nonactivating panel may join other applications' native
                // fullscreen spaces without taking their keyboard focus.
                // Include Dock/Launchpad, menu bar and ordinary pop-up menus in
                // the live composite. Keep below screen saver/security surfaces.
                // Mouse events still pass through; the configurable hotkey remains the exit.
                overlay.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
                overlay.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications,
                                              .fullScreenAuxiliary, .stationary, .ignoresCycle]
                overlay.contentView = renderer
                overlay.setFrame(screen.frame, display: false)
                self.renderer = renderer
                self.overlay = overlay
                capturedDisplayID = display.displayID
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
                self.stream = stream
                captureFPS = 30
                updatingCaptureRate = false
                startedAt = Date()
                if !automatically { receivedFrame = false }
                try await stream.startCapture()
                guard token == generation else {
                    try? await stream.stopCapture()
                    return
                }
                starting = false
                if !sleepReasons.isEmpty {
                    suspend(reason: "保留画面，等待开盖继续")
                    return
                }
                recoveryTimer?.invalidate()
                recoveryTimer = nil
                if previewRequested {
                    previewUntil = Date().addingTimeInterval(8)
                    previewRequested = false
                }
                model.statusText = previewOnly ? "预览中（8 秒）" : "Duo 效果已启用"
                logger.info("Duo capture started")
                resumeRendering()
            } catch {
                guard token == generation else { return }
                let failedStream = self.stream
                self.stream = nil
                starting = false
                if let failedStream { Task { try? await failedStream.stopCapture() } }
                if automatically || !sleepReasons.isEmpty {
                    recoveryFailures += 1
                    nextRecoveryAttempt = Date().addingTimeInterval(DuoEffectPolicy.retryDelay(failures: recoveryFailures))
                    suspend(reason: "等待解锁或桌面捕获恢复：\(error.localizedDescription)")
                    return
                }
                failureStatus = "无法启动：\(error.localizedDescription)。请检查系统设置 → 隐私与安全性 → 屏幕录制权限。"
                stop(reason: "已停止")
                onFailure()
            }
        }
    }

    private func suspend(reason: String) {
        guard resumeWanted || stream != nil || starting else { return }
        // Suspension must not destroy the window, GPU textures, or healthy stream.
        timer?.invalidate()
        timer = nil
        renderer?.isPaused = true
        overlay?.orderOut(nil)
        model.statusText = reason
        logger.info("Duo effect suspended (resources retained): \(reason, privacy: .public)")
        if recoveryTimer == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.recoverIfReady() }
            }
            recoveryTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func recoverIfReady() {
        guard resumeWanted, sleepReasons.isEmpty, !starting,
              Date() >= nextRecoveryAttempt,
              model.sensor.isAvailable,
              Date().timeIntervalSince(model.sensor.lastSuccessfulUpdate) < 0.5,
              NSScreen.screens.contains(where: {
                  guard let id = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return false }
                  return CGDisplayIsBuiltin(id) != 0 && CGDisplayIsActive(id) != 0
              }) else { return }
        if stream != nil {
            recoveryTimer?.invalidate()
            recoveryTimer = nil
            startedAt = Date()
            resumeRendering()
            model.statusText = "开盖继续显示 · 窗口与画面已保留"
            logger.info("Duo effect resumed using existing stream and renderer")
            return
        }
        // Wake recovery must never open a fresh permission prompt by itself.
        guard CGPreflightScreenCaptureAccess() else {
            nextRecoveryAttempt = Date().addingTimeInterval(5)
            suspend(reason: "等待屏幕录制权限恢复；若权限已撤销，请到系统设置重新允许")
            return
        }
        start(automatically: true)
    }

    private func resumeRendering() {
        renderer?.isPaused = false
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        update()
    }

    private func update() {
        guard sleepReasons.isEmpty else { return }
        guard let renderer, let overlay else { return }
        guard let id = capturedDisplayID,
              let targetScreen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
              }), CGDisplayIsBuiltin(id) != 0, CGDisplayIsActive(id) != 0 else {
            screenConfigurationChanged()
            suspend(reason: "等待 MacBook 内建屏幕恢复")
            return
        }
        if overlay.frame != targetScreen.frame {
            screenConfigurationChanged()
            return
        }
        if Date().timeIntervalSince(model.sensor.lastSuccessfulUpdate) > 2 {
            suspend(reason: "等待铰链数据恢复后自动继续")
            return
        }
        if !receivedFrame && Date().timeIntervalSince(startedAt) > 8 {
            let stalledStream = stream
            stream = nil
            if let stalledStream { Task { try? await stalledStream.stopCapture() } }
            nextRecoveryAttempt = Date().addingTimeInterval(2)
            suspend(reason: "等待唤醒后的桌面画面，正在重新连接")
            return
        }
        let previewActive = Date() < previewUntil
        if previewOnly && !previewActive {
            stop(reason: "预览已结束")
            return
        }
        // A static desktop may legitimately produce no new complete frames.
        // Keep the last valid texture; explicit stream errors still stop immediately.
        let remaining = DuoEffectPolicy.remaining(angle: model.sensor.angle, velocity: model.sensor.velocity,
                                                  endpoint: model.openAngle, preview: previewActive)
        updateCaptureRate(DuoEffectPolicy.captureFPS(remaining: remaining, velocity: model.sensor.velocity),
                          screen: targetScreen)
        renderer.setFrost(model.frost)
        renderer.setLiveAngle(remaining * 80)
        // Hysteresis prevents overlay flicker near the calibrated endpoint.
        if remaining > 0.008 { requestedVisible = true }
        if remaining == 0 && renderer.settled { requestedVisible = false }
        if requestedVisible && receivedFrame && renderer.readyForDisplay {
            if !overlay.isVisible { overlay.orderFrontRegardless() }
        } else { overlay.orderOut(nil) }
        statusTick += 1
        if statusTick % 30 == 0 {
            let state = overlay.isVisible ? "效果显示中" : "原桌面"
            model.statusText = previewOnly
                ? "预览中（8 秒）"
                : "\(state) · 铰链 \(Int(model.sensor.angle))° · 终点 \(Int(model.openAngle))°"
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard self.stream === stream, type == .screen, sampleBuffer.isValid else { return }
        guard sleepReasons.isEmpty else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        renderer?.receive(buffer)
        recoveryFailures = 0
        receivedFrame = true
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            self.stream = nil
            recoveryFailures += 1
            nextRecoveryAttempt = Date().addingTimeInterval(DuoEffectPolicy.retryDelay(failures: recoveryFailures))
            suspend(reason: "捕获暂时中断，解锁后自动重试：\(error.localizedDescription)")
        }
    }

    private func updateCaptureRate(_ fps: Int32, screen: NSScreen) {
        guard fps != captureFPS, !updatingCaptureRate, let stream else { return }
        updatingCaptureRate = true
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width)
        config.height = Int(screen.frame.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false
        Task { @MainActor in
            do {
                try await stream.updateConfiguration(config)
                guard self.stream === stream else { return }
                captureFPS = fps
            } catch {
                // Keep the functioning stream if a power-saving update fails.
                guard self.stream === stream else { return }
                captureFPS = fps
                logger.error("Duo capture rate update failed: \(error.localizedDescription, privacy: .public)")
            }
            updatingCaptureRate = false
        }
    }

    enum DuoError: LocalizedError {
        case noInternalDisplay, cannotExcludeSelf, noGPU
        var errorDescription: String? {
            switch self {
            case .noInternalDisplay: return "未找到内建显示屏"
            case .cannotExcludeSelf: return "无法排除自身窗口，为避免重复捕获已取消"
            case .noGPU: return "Metal 不可用"
            }
        }
    }
}
