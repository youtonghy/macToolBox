import CoreGraphics
import Foundation
import ToolBoxControlProtocol

enum ToolBoxCommandRouterError: LocalizedError {
    case applicationUnavailable

    var errorDescription: String? {
        switch self {
        case .applicationUnavailable:
            return "ToolBox 应用服务不可用。"
        }
    }
}

@MainActor
final class ToolBoxCommandRouter: ToolBoxControlRequestHandling {
    private let displayControl: DisplayControlService
    private let audioRouting: AudioRoutingService
    private let focusMode: FocusModeCoordinator
    private let awake: AwakeCoordinator
    private let state: FeatureState
    private let launchAtLogin: LaunchAtLoginController

    init(
        displayControl: DisplayControlService,
        audioRouting: AudioRoutingService,
        focusMode: FocusModeCoordinator,
        awake: AwakeCoordinator,
        state: FeatureState,
        launchAtLogin: LaunchAtLoginController
    ) {
        self.displayControl = displayControl
        self.audioRouting = audioRouting
        self.focusMode = focusMode
        self.awake = awake
        self.state = state
        self.launchAtLogin = launchAtLogin
    }

    func handle(_ request: ToolBoxControlRequestEnvelope) async throws -> ToolBoxControlResponseEnvelope {
        do {
            let result: ToolBoxControlResult
            let warnings: [ToolBoxControlWarningDTO]
            switch request.request {
            case .status:
                result = .status(makeStatus())
                warnings = []
            case .displayList:
                result = .displayList(makeDisplayList())
                warnings = []
            case let .displayGet(target):
                result = .display(makeDisplayDTO(try resolveDisplay(target)))
                warnings = []
            case let .displaySet(payload):
                let display = try resolveDisplay(payload.target)
                try applyDisplayChange(payload.change, to: display)
                result = .display(makeDisplayDTO(display))
                warnings = [.init(code: .writeUnverified, message: "写入已提交；显示器回读将在后台完成。", details: ["displayId": String(display.id)])]
            case .focusStatus:
                result = .focus(makeFocusDTO())
                warnings = []
            case let .focusSet(payload):
                if let enabled = payload.isEnabled { focusMode.setEnabled(enabled) }
                if let opacity = payload.opacityPercent {
                    guard (20...85).contains(opacity) else {
                        return failure(request, code: .invalidRequest, message: "透明度必须在 20...85 之间。")
                    }
                    focusMode.setOverlayOpacity(Double(opacity) / 100)
                }
                result = .focus(makeFocusDTO())
                warnings = []
            case .audioApps:
                result = .audioApps(makeAudioApps())
                warnings = []
            case .audioDevices:
                result = .audioDevices(makeAudioDevices())
                warnings = []
            case let .audioGet(payload):
                guard let row = audioRouting.rows.first(where: { $0.bundleID == payload.bundleID }) else {
                    return failure(request, code: .notFound, message: "找不到音频应用或已保存规则：\(payload.bundleID)。")
                }
                result = .audioRule(makeAudioRule(row))
                warnings = []
            case let .audioSet(payload):
                try applyAudioChange(payload.change, bundleID: payload.bundleID)
                guard let row = audioRouting.rows.first(where: { $0.bundleID == payload.bundleID }) else {
                    return failure(request, code: .operationFailed, message: "音频规则已提交，但暂时无法读取结果。")
                }
                result = .audioRule(makeAudioRule(row))
                warnings = [.init(code: .configuredNotActive, message: "规则已保存；应用未输出音频时不会立即生效。")]
            case let .awake(toggle):
                warnings = try applyAwake(toggle.action)
                result = .awake(.init(isEnabled: awake.isEnabled))
            case let .launchAtLogin(toggle):
                try applyLaunchAtLogin(toggle.action)
                result = .launchAtLogin(.init(isEnabled: launchAtLogin.isEnabled))
                warnings = []
            }
            return .success(requestID: request.requestID, result: result, warnings: warnings)
        } catch let error as ToolBoxDisplayTargetError {
            return failure(request, code: error.code, message: error.localizedDescription)
        } catch let error as DisplayControlError {
            return failure(request, code: .unavailable, message: error.localizedDescription)
        } catch {
            return failure(request, code: .operationFailed, message: error.localizedDescription)
        }
    }

    private func makeStatus() -> ToolBoxStatusDTO {
        let displays = controllableDisplays
        let capabilities = [
            ToolBoxCapabilityDTO(name: "display", isAvailable: !displays.isEmpty),
            ToolBoxCapabilityDTO(name: "audio", isAvailable: audioRouting.globalError == nil, reason: audioRouting.globalError),
            ToolBoxCapabilityDTO(name: "focus", isAvailable: focusMode.permissionState == .granted, reason: focusMode.permissionState == .granted ? nil : "需要辅助功能权限。"),
            ToolBoxCapabilityDTO(name: "awake", isAvailable: true),
            ToolBoxCapabilityDTO(name: "launch-at-login", isAvailable: true),
        ]
        return .init(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            capabilities: capabilities,
            displayCount: displays.count,
            audioAppCount: audioRouting.rows.count,
            focusEnabled: focusMode.isEnabled,
            awakeEnabled: awake.isEnabled,
            launchAtLoginEnabled: launchAtLogin.isEnabled
        )
    }

    private var controllableDisplays: [DisplayControlDisplay] {
        displayControl.snapshot.displays.filter { !$0.isBuiltIn && !$0.isVirtual }
    }

    private func makeDisplayList() -> ToolBoxDisplayListDTO {
        .init(displays: controllableDisplays.map(makeDisplayDTO))
    }

    private func resolveDisplay(_ target: ToolBoxDisplayTargetDTO) throws -> DisplayControlDisplay {
        let matches: [DisplayControlDisplay]
        if let displayID = target.displayID {
            matches = controllableDisplays.filter { $0.id == displayID }
        } else if let serial = target.serial {
            matches = controllableDisplays.filter { $0.serialNumber.map(String.init) == serial }
        } else {
            matches = controllableDisplays
        }
        guard !matches.isEmpty else { throw ToolBoxDisplayTargetError.notFound }
        guard matches.count == 1 else { throw ToolBoxDisplayTargetError.ambiguous }
        return matches[0]
    }

    private func makeDisplayDTO(_ display: DisplayControlDisplay) -> ToolBoxDisplayDTO {
        let controls = display.controls.map { capability in
            ToolBoxDisplayControlDTO(
                kind: ToolBoxDisplayControlKind(rawValue: capability.kind.rawValue)!,
                minimum: capability.value.map { Int($0.rawMinimum) },
                maximum: capability.value.map { Int($0.rawMaximum) },
                currentValue: currentValue(for: capability),
                isReadable: capability.value != nil,
                isWritable: capability.status.isWritable
            )
        } + (display.colorPreset.map { preset in
            [ToolBoxDisplayControlDTO(
                kind: .preset,
                currentValue: preset.currentRawValue.map(String.init),
                isReadable: preset.currentRawValue != nil,
                isWritable: preset.status == .available
            )]
        } ?? [])
        return .init(
            displayID: display.id,
            serial: display.serialNumber.map(String.init),
            name: display.name,
            isBuiltIn: display.isBuiltIn,
            controls: controls
        )
    }

    private func currentValue(for capability: DisplayControlCapability) -> String? {
        guard let value = capability.value else { return nil }
        if capability.kind == .mute { return value.normalized >= 0.5 ? "true" : "false" }
        return String(Int((value.normalized * 100).rounded()))
    }

    private func applyDisplayChange(_ change: ToolBoxDisplayChangeDTO, to display: DisplayControlDisplay) throws {
        switch change {
        case let .brightness(value):
            displayControl.writeControl(displayID: display.id, kind: .brightness, normalizedValue: Double(value) / 100)
        case let .contrast(value):
            displayControl.writeControl(displayID: display.id, kind: .contrast, normalizedValue: Double(value) / 100)
        case let .volume(value):
            displayControl.setVolume(displayID: display.id, normalizedValue: Double(value) / 100)
        case let .mute(value):
            displayControl.setMuted(displayID: display.id, muted: value)
        case let .preset(value):
            guard let rawValue = parsePreset(value, display: display) else { throw ToolBoxDisplayTargetError.invalidPreset }
            displayControl.setColorPreset(displayID: display.id, rawValue: rawValue)
        }
    }

    private func parsePreset(_ value: String, display: DisplayControlDisplay) -> UInt8? {
        if let rawValue = UInt8(value) { return rawValue }
        if value.lowercased().hasPrefix("0x") { return UInt8(value.dropFirst(2), radix: 16) }
        return display.colorPreset?.options.first { $0.name.caseInsensitiveCompare(value) == .orderedSame }?.rawValue
    }

    private func makeFocusDTO() -> ToolBoxFocusDTO {
        .init(isEnabled: focusMode.isEnabled, opacityPercent: Int((focusMode.overlayOpacity * 100).rounded()), permissionGranted: focusMode.permissionState == .granted)
    }

    private func makeAudioApps() -> ToolBoxAudioAppListDTO {
        .init(apps: audioRouting.rows.map { row in
            .init(bundleID: row.bundleID, name: row.name, isRunning: row.isRunning, isProducingOutput: row.isCurrentlyPlaying, hasSavedRule: row.outputDeviceUID != nil || row.volumePercent != 100)
        })
    }

    private func makeAudioDevices() -> ToolBoxAudioDeviceListDTO {
        .init(devices: audioRouting.devices.map { device in
            .init(uid: device.uid, name: device.name, isAvailable: device.isAvailable, isRoutable: device.isRoutable, sampleRate: device.sampleRate, issue: device.compatibilityIssue.map(String.init(describing:)))
        })
    }

    private func makeAudioRule(_ row: AudioRoutingRow) -> ToolBoxAudioRuleDTO {
        let state: ToolBoxAudioRuleState
        let issue: String?
        switch row.state {
        case .active:
            state = .active; issue = nil
        case let .degraded(message), let .failed(message), let .awaitingAudio(message):
            state = .failed; issue = message
        case .waitingForProcess, .starting:
            state = .pending; issue = nil
        case .inactive:
            state = .configured; issue = nil
        }
        return .init(bundleID: row.bundleID, volumePercent: row.volumePercent, outputDeviceUID: row.outputDeviceUID, state: state, issue: issue)
    }

    private func applyAudioChange(_ change: ToolBoxAudioChangeDTO, bundleID: String) throws {
        guard !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolBoxDisplayTargetError.invalidBundleID }
        switch change {
        case let .volume(percent):
            guard (0...300).contains(percent) else { throw ToolBoxDisplayTargetError.invalidVolume }
            audioRouting.setVolume(bundleID: bundleID, percent: percent)
        case let .outputDevice(selection):
            switch selection {
            case .systemDefault:
                audioRouting.setOutputDevice(bundleID: bundleID, uid: nil)
            case let .device(uid):
                guard audioRouting.devices.contains(where: { $0.uid == uid }) else { throw ToolBoxDisplayTargetError.deviceNotFound }
                audioRouting.setOutputDevice(bundleID: bundleID, uid: uid)
            }
        }
    }

    private func applyAwake(_ action: ToolBoxToggleAction) throws -> [ToolBoxControlWarningDTO] {
        switch action {
        case .status:
            return []
        case .on:
            let degradedMessage = try awake.start()
            state.awakeOn = awake.isEnabled
            if let degradedMessage {
                return [.init(code: .degraded, message: "系统断言已启用，但 caffeinate 未能启动：\(degradedMessage)")]
            }
            return []
        case .off:
            awake.stop()
            state.awakeOn = false
            return []
        }
    }

    private func applyLaunchAtLogin(_ action: ToolBoxToggleAction) throws {
        switch action {
        case .status:
            launchAtLogin.refresh()
        case .on:
            try launchAtLogin.setEnabledOrThrow(true)
        case .off:
            try launchAtLogin.setEnabledOrThrow(false)
        }
    }

    private func failure(_ request: ToolBoxControlRequestEnvelope, code: ToolBoxControlErrorCode, message: String) -> ToolBoxControlResponseEnvelope {
        .failure(requestID: request.requestID, error: .init(code: code, message: message))
    }
}

private enum ToolBoxDisplayTargetError: LocalizedError {
    case notFound
    case ambiguous
    case invalidPreset
    case invalidBundleID
    case invalidVolume
    case deviceNotFound

    var code: ToolBoxControlErrorCode {
        switch self {
        case .notFound, .deviceNotFound: return .notFound
        case .ambiguous: return .ambiguousTarget
        case .invalidPreset, .invalidBundleID, .invalidVolume: return .invalidRequest
        }
    }

    var errorDescription: String? {
        switch self {
        case .notFound: return "找不到匹配的显示器。"
        case .ambiguous: return "显示器目标不唯一，请指定 --display-id 或 --serial。"
        case .invalidPreset: return "预设值无效，必须是数字、0x 十六进制值或显示器提供的预设名称。"
        case .invalidBundleID: return "Bundle ID 不能为空。"
        case .invalidVolume: return "音量必须在 0...300 之间。"
        case .deviceNotFound: return "找不到指定的音频输出设备。"
        }
    }
}
