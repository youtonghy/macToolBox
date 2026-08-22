import Foundation
import ToolBoxControlProtocol

enum ToolBoxCLIExitStatus {
    static let success: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 64
    static let unavailable: Int32 = 69
    static let permissionDenied: Int32 = 77
}

struct ToolBoxCLIRenderedOutput: Equatable {
    let standardOutput: String
    let standardError: String
    let exitStatus: Int32
}

protocol ToolBoxCLIWriting {
    func writeStandardOutput(_ text: String)
    func writeStandardError(_ text: String)
}

struct ToolBoxCLIWriter: ToolBoxCLIWriting {
    func writeStandardOutput(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        FileHandle.standardOutput.write(data)
    }

    func writeStandardError(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}

struct ToolBoxCLIResponseRenderer {
    func render(
        _ response: ToolBoxControlResponseEnvelope,
        asJSON: Bool
    ) -> ToolBoxCLIRenderedOutput {
        if asJSON {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(response)
                let text = String(decoding: data, as: UTF8.self) + "\n"
                return ToolBoxCLIRenderedOutput(
                    standardOutput: text,
                    standardError: "",
                    exitStatus: exitStatus(for: response.error)
                )
            } catch {
                return ToolBoxCLIRenderedOutput(
                    standardOutput: "",
                    standardError: "错误：无法编码 JSON 输出：\(error.localizedDescription)\n",
                    exitStatus: ToolBoxCLIExitStatus.failure
                )
            }
        }

        var standardError = response.warnings.map {
            "警告 [\($0.code.rawValue)]：\($0.message)"
        }.joined(separator: "\n")
        if !standardError.isEmpty {
            standardError += "\n"
        }
        if let error = response.error {
            standardError += "错误 [\(error.code.rawValue)]：\(error.message)\n"
            return ToolBoxCLIRenderedOutput(
                standardOutput: "",
                standardError: standardError,
                exitStatus: exitStatus(for: error)
            )
        }
        guard let result = response.result else {
            return ToolBoxCLIRenderedOutput(
                standardOutput: "",
                standardError: standardError + "错误：ToolBox 响应缺少结果\n",
                exitStatus: ToolBoxCLIExitStatus.failure
            )
        }
        return ToolBoxCLIRenderedOutput(
            standardOutput: renderHumanResult(result),
            standardError: standardError,
            exitStatus: ToolBoxCLIExitStatus.success
        )
    }

    func renderClientError(
        _ error: ToolBoxCLIClientError,
        requestID: String,
        asJSON: Bool
    ) -> ToolBoxCLIRenderedOutput {
        let response = ToolBoxControlResponseEnvelope.failure(
            requestID: requestID,
            error: ToolBoxControlErrorDTO(
                code: controlErrorCode(for: error),
                message: error.localizedDescription
            )
        )
        return render(response, asJSON: asJSON)
    }

    func renderInstallResult(
        _ result: ToolBoxCLIInstallOutputDTO,
        asJSON: Bool
    ) -> ToolBoxCLIRenderedOutput {
        if asJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(result) else {
                return ToolBoxCLIRenderedOutput(
                    standardOutput: "",
                    standardError: "错误：无法编码 JSON 输出\n",
                    exitStatus: ToolBoxCLIExitStatus.failure
                )
            }
            return ToolBoxCLIRenderedOutput(
                standardOutput: String(decoding: data, as: UTF8.self) + "\n",
                standardError: "",
                exitStatus: ToolBoxCLIExitStatus.success
            )
        }

        let message: String
        switch result.state {
        case .installed:
            message = "已安装：\(result.path)"
        case .alreadyInstalled:
            message = "已安装，无需更改：\(result.path)"
        case .uninstalled:
            message = "已卸载：\(result.path)"
        }
        return ToolBoxCLIRenderedOutput(
            standardOutput: message + "\n",
            standardError: "",
            exitStatus: ToolBoxCLIExitStatus.success
        )
    }

    func renderInstallError(_ error: Error, asJSON: Bool) -> ToolBoxCLIRenderedOutput {
        let message = error.localizedDescription
        if asJSON {
            struct InstallErrorDTO: Codable {
                let error: ErrorDTO

                struct ErrorDTO: Codable {
                    let code: String
                    let message: String
                }
            }
            let payload = InstallErrorDTO(error: .init(code: "install-failed", message: message))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = (try? encoder.encode(payload)) ?? Data()
            return ToolBoxCLIRenderedOutput(
                standardOutput: String(decoding: data, as: UTF8.self) + "\n",
                standardError: "",
                exitStatus: ToolBoxCLIExitStatus.failure
            )
        }
        return ToolBoxCLIRenderedOutput(
            standardOutput: "",
            standardError: "错误：\(message)\n",
            exitStatus: ToolBoxCLIExitStatus.failure
        )
    }

    private func renderHumanResult(_ result: ToolBoxControlResult) -> String {
        switch result {
        case let .status(status):
            let available = status.capabilities.filter(\.isAvailable).map(\.name).joined(separator: ", ")
            return """
            ToolBox \(status.appVersion)（PID \(status.processIdentifier)）
            显示器：\(status.displayCount)
            音频应用：\(status.audioAppCount)
            聚焦模式：\(onOff(status.focusEnabled))
            防休眠：\(onOff(status.awakeEnabled))
            登录时启动：\(onOff(status.launchAtLoginEnabled))
            可用能力：\(available.isEmpty ? "无" : available)
            """ + "\n"
        case let .displayList(list):
            guard !list.displays.isEmpty else { return "未发现可控显示器\n" }
            return list.displays.map(renderDisplaySummary).joined(separator: "\n") + "\n"
        case let .display(display):
            let controls = display.controls.map { control in
                let value = control.currentValue ?? "不可读"
                return "  \(control.kind.rawValue)：\(value)"
            }.joined(separator: "\n")
            return renderDisplaySummary(display) + (controls.isEmpty ? "\n" : "\n\(controls)\n")
        case let .focus(focus):
            return "聚焦模式：\(onOff(focus.isEnabled))\n透明度：\(focus.opacityPercent)%\n辅助功能权限：\(focus.permissionGranted ? "已授权" : "未授权")\n"
        case let .audioApps(list):
            guard !list.apps.isEmpty else { return "未发现音频应用\n" }
            return list.apps.map { app in
                let state = app.isProducingOutput ? "正在输出" : (app.isRunning ? "运行中" : "未运行")
                return "\(app.name)\t\(app.bundleID)\t\(state)\(app.hasSavedRule ? "\t已配置" : "")"
            }.joined(separator: "\n") + "\n"
        case let .audioDevices(list):
            guard !list.devices.isEmpty else { return "未发现音频输出设备\n" }
            return list.devices.map { device in
                let state = device.isRoutable ? "可路由" : (device.issue ?? "不可路由")
                return "\(device.name)\t\(device.uid)\t\(state)"
            }.joined(separator: "\n") + "\n"
        case let .audioRule(rule):
            return "应用：\(rule.bundleID)\n音量：\(rule.volumePercent)%\n输出：\(rule.outputDeviceUID ?? "system-default")\n状态：\(rule.state.rawValue)\(rule.issue.map { "\n说明：\($0)" } ?? "")\n"
        case let .awake(state):
            return "防休眠：\(onOff(state.isEnabled))\n"
        case let .launchAtLogin(state):
            return "登录时启动：\(onOff(state.isEnabled))\n"
        }
    }

    private func renderDisplaySummary(_ display: ToolBoxDisplayDTO) -> String {
        let serial = display.serial.map { "，序列号 \($0)" } ?? ""
        let kind = display.isBuiltIn ? "内建" : "外接"
        return "\(display.name)（ID \(display.displayID)\(serial)，\(kind)）"
    }

    private func onOff(_ value: Bool) -> String {
        value ? "开启" : "关闭"
    }

    private func controlErrorCode(for error: ToolBoxCLIClientError) -> ToolBoxControlErrorCode {
        switch error {
        case .protocolVersionMismatch:
            return .unsupportedProtocolVersion
        case .requestTimedOut, .applicationLaunchTimedOut:
            return .timedOut
        default:
            return .unavailable
        }
    }

    private func exitStatus(for error: ToolBoxControlErrorDTO?) -> Int32 {
        guard let error else { return ToolBoxCLIExitStatus.success }
        switch error.code {
        case .invalidRequest:
            return ToolBoxCLIExitStatus.usage
        case .permissionDenied:
            return ToolBoxCLIExitStatus.permissionDenied
        case .unavailable, .timedOut, .unsupportedProtocolVersion:
            return ToolBoxCLIExitStatus.unavailable
        case .notFound,
             .ambiguousTarget,
             .unsupported,
             .conflict,
             .operationFailed,
             .internalError:
            return ToolBoxCLIExitStatus.failure
        }
    }
}

struct ToolBoxCLICommandExecutor {
    let client: ToolBoxControlClient
    let renderer: ToolBoxCLIResponseRenderer
    let writer: ToolBoxCLIWriting

    init(
        client: ToolBoxControlClient = ToolBoxControlClient(),
        renderer: ToolBoxCLIResponseRenderer = ToolBoxCLIResponseRenderer(),
        writer: ToolBoxCLIWriting = ToolBoxCLIWriter()
    ) {
        self.client = client
        self.renderer = renderer
        self.writer = writer
    }

    func execute(
        request: ToolBoxControlRequest,
        options: ToolBoxCLIConnectionOptions
    ) -> Int32 {
        let envelope = ToolBoxControlRequestEnvelope(request: request)
        let rendered: ToolBoxCLIRenderedOutput
        do {
            let response = try client.execute(
                envelope,
                options: ToolBoxControlClientOptions(
                    shouldLaunchApplication: !options.noLaunch,
                    timeout: options.timeout
                )
            )
            rendered = renderer.render(response, asJSON: options.json)
        } catch let error as ToolBoxCLIClientError {
            rendered = renderer.renderClientError(
                error,
                requestID: envelope.requestID,
                asJSON: options.json
            )
        } catch {
            let fallback = ToolBoxControlResponseEnvelope.failure(
                requestID: envelope.requestID,
                error: ToolBoxControlErrorDTO(
                    code: .internalError,
                    message: error.localizedDescription
                )
            )
            rendered = renderer.render(fallback, asJSON: options.json)
        }
        writer.writeStandardOutput(rendered.standardOutput)
        writer.writeStandardError(rendered.standardError)
        return rendered.exitStatus
    }
}
