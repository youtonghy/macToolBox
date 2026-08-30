import ArgumentParser
import Foundation
import ToolBoxControlProtocol

struct ToolBoxCLIConnectionOptions: ParsableArguments {
    @Flag(name: .long, help: "以稳定的 JSON 格式输出结果。")
    var json = false

    @Flag(name: .long, help: "ToolBox 未运行时不自动启动应用。")
    var noLaunch = false

    @Option(
        name: .long,
        help: ArgumentHelp("等待应用启动和命令响应的秒数。", valueName: "seconds")
    )
    var timeout: Double = 10

    func validateValues() throws {
        guard timeout.isFinite, timeout > 0, timeout <= 300 else {
            throw ValidationError("--timeout 必须大于 0 且不超过 300 秒。")
        }
    }
}

struct ToolBoxCLIOutputOptions: ParsableArguments {
    @Flag(name: .long, help: "以稳定的 JSON 格式输出结果。")
    var json = false
}

struct ToolBoxDisplaySelectorOptions: ParsableArguments {
    @Option(
        name: .customLong("display-id"),
        help: ArgumentHelp("按 CoreGraphics display ID 选择显示器。", valueName: "id")
    )
    var displayID: UInt32?

    @Option(
        name: .long,
        help: ArgumentHelp("按显示器序列号选择显示器。", valueName: "serial")
    )
    var serial: String?

    func validateValues() throws {
        guard displayID == nil || serial == nil else {
            throw ValidationError("--display-id 与 --serial 只能指定一个。")
        }
        if let serial, serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--serial 不能为空。")
        }
    }

    var dto: ToolBoxDisplayTargetDTO {
        ToolBoxDisplayTargetDTO(displayID: displayID, serial: serial)
    }
}

enum ToolBoxOnOffValue: String, ExpressibleByArgument {
    case on
    case off

    var boolValue: Bool { self == .on }
}

enum ToolBoxBooleanValue: String, ExpressibleByArgument {
    case `true`
    case `false`

    var boolValue: Bool { self == .true }
}

func runToolBoxRequest(
    _ request: ToolBoxControlRequest,
    options: ToolBoxCLIConnectionOptions
) throws {
    let status = ToolBoxCLICommandExecutor().execute(request: request, options: options)
    if status != ToolBoxCLIExitStatus.success {
        throw ExitCode(status)
    }
}

struct ToolBoxStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "显示 ToolBox 应用和各控制功能的当前状态。"
    )

    @OptionGroup var options: ToolBoxCLIConnectionOptions

    mutating func validate() throws {
        try options.validateValues()
    }

    mutating func run() throws {
        try runToolBoxRequest(.status, options: options)
    }
}

struct ToolBoxDisplayCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "display",
        abstract: "查询或控制显示器。",
        subcommands: [List.self, Get.self, Set.self]
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "列出可控显示器及其标识。"
        )

        @OptionGroup var options: ToolBoxCLIConnectionOptions

        mutating func validate() throws {
            try options.validateValues()
        }

        mutating func run() throws {
            try runToolBoxRequest(.displayList, options: options)
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "读取一个显示器的当前控制值。",
            discussion: "省略显示器标识时，仅在恰好存在一个可控外接显示器时自动选择。"
        )

        @OptionGroup var selector: ToolBoxDisplaySelectorOptions
        @OptionGroup var options: ToolBoxCLIConnectionOptions

        mutating func validate() throws {
            try selector.validateValues()
            try options.validateValues()
        }

        mutating func run() throws {
            try runToolBoxRequest(.displayGet(selector.dto), options: options)
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "修改一个显示器的一项设置。",
            discussion: "一次只能修改亮度、对比度、音量、静音或预设中的一项。"
        )

        @OptionGroup var selector: ToolBoxDisplaySelectorOptions
        @Option(name: .long, help: "设置亮度百分比（0...100）。")
        var brightness: Int?
        @Option(name: .long, help: "设置对比度百分比（0...100）。")
        var contrast: Int?
        @Option(name: .long, help: "设置显示器音量百分比（0...100）。")
        var volume: Int?
        @Option(name: .long, help: ArgumentHelp("设置静音状态。", valueName: "on|off"))
        var mute: ToolBoxOnOffValue?
        @Option(name: .long, help: ArgumentHelp("设置显示器颜色预设。", valueName: "value"))
        var preset: String?
        @Option(name: .long, help: "写入后轮询回读以确认结果（秒，1...60）。预设写入自带服务端回读验证，无需此选项。")
        var wait: Int?
        @OptionGroup var options: ToolBoxCLIConnectionOptions

        mutating func validate() throws {
            try selector.validateValues()
            try options.validateValues()
            let count = [brightness != nil, contrast != nil, volume != nil, mute != nil, preset != nil]
                .filter { $0 }
                .count
            guard count == 1 else {
                throw ValidationError("必须且只能指定 --brightness、--contrast、--volume、--mute 或 --preset 中的一项。")
            }
            for (name, value) in [("brightness", brightness), ("contrast", contrast), ("volume", volume)] {
                if let value, !(0...100).contains(value) {
                    throw ValidationError("--\(name) 必须在 0...100 之间。")
                }
            }
            if let preset, preset.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--preset 不能为空。")
            }
            if let wait, !(1...60).contains(wait) {
                throw ValidationError("--wait 必须在 1...60 之间。")
            }
        }

        mutating func run() throws {
            let change: ToolBoxDisplayChangeDTO
            if let brightness {
                change = .brightness(brightness)
            } else if let contrast {
                change = .contrast(contrast)
            } else if let volume {
                change = .volume(volume)
            } else if let mute {
                change = .mute(mute.boolValue)
            } else if let preset {
                change = .preset(preset)
            } else {
                throw ValidationError("缺少显示器设置。")
            }

            let executor = ToolBoxCLICommandExecutor()
            let setStatus = executor.execute(
                request: .displaySet(ToolBoxDisplaySetRequestDTO(target: selector.dto, change: change)),
                options: options
            )
            guard setStatus == ToolBoxCLIExitStatus.success else {
                throw ExitCode(setStatus)
            }
            guard let wait, !isPresetChange(change) else { return }

            let confirmed = Self.waitForReadback(
                selector: selector.dto,
                change: change,
                timeoutSeconds: wait,
                options: options
            )
            let writer = ToolBoxCLIWriter()
            if case let .unconfirmed(detail) = confirmed {
                writer.writeStandardError("✗ 回读确认失败：\(detail)\n")
                throw ExitCode(ToolBoxCLIExitStatus.failure)
            }
            writer.writeStandardOutput("✓ 回读确认成功。\n")
        }

        private func isPresetChange(_ change: ToolBoxDisplayChangeDTO) -> Bool {
            if case .preset = change { return true }
            return false
        }

        private enum ReadbackConfirmation {
            case confirmed
            case unconfirmed(String)
        }

        /// Polls displayGet until the readback matches the requested change.
        /// Write-only displays cannot be verified and report unconfirmed.
        private static func waitForReadback(
            selector: ToolBoxDisplayTargetDTO,
            change: ToolBoxDisplayChangeDTO,
            timeoutSeconds: Int,
            options: ToolBoxCLIConnectionOptions
        ) -> ReadbackConfirmation {
            let client = ToolBoxControlClient()
            let clientOptions = ToolBoxControlClientOptions(
                shouldLaunchApplication: false,
                timeout: options.timeout
            )
            let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))

            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
                guard
                    let response = try? client.execute(
                        ToolBoxControlRequestEnvelope(request: .displayGet(selector)),
                        options: clientOptions
                    ),
                    response.error == nil,
                    let result = response.result,
                    case .display(let dto) = result,
                    let verdict = Self.readbackVerdict(for: dto, change: change)
                else {
                    continue
                }
                return verdict
            }
            return .unconfirmed("等待回读超时（\(timeoutSeconds) 秒）")
        }

        /// Returns nil while the readback has not converged on the target yet
        /// (keep polling); a verdict ends the wait.
        private static func readbackVerdict(
            for dto: ToolBoxDisplayDTO,
            change: ToolBoxDisplayChangeDTO
        ) -> ReadbackConfirmation? {
            switch change {
            case let .brightness(target):
                return numericVerdict(for: dto, kind: .brightness, target: target)
            case let .contrast(target):
                return numericVerdict(for: dto, kind: .contrast, target: target)
            case let .volume(target):
                return numericVerdict(for: dto, kind: .volume, target: target)
            case let .mute(target):
                guard let control = dto.controls.first(where: { $0.kind == .mute }) else {
                    return .unconfirmed("显示器未上报静音控制")
                }
                guard control.isReadable, let current = control.currentValue else {
                    return .unconfirmed("静音状态不可回读（write-only）")
                }
                if (current == "true") == target {
                    return .confirmed
                }
                return nil
            case .preset:
                return .unconfirmed("预设写入已由服务端回读验证，无需 --wait")
            }
        }

        private static func numericVerdict(
            for dto: ToolBoxDisplayDTO,
            kind: ToolBoxDisplayControlKind,
            target: Int
        ) -> ReadbackConfirmation? {
            guard let control = dto.controls.first(where: { $0.kind == kind }) else {
                return .unconfirmed("显示器未上报该控制项")
            }
            guard control.isReadable, let current = control.currentValue, let value = Int(current) else {
                return .unconfirmed("当前值不可回读（write-only）")
            }
            if abs(value - target) <= 2 {
                return .confirmed
            }
            return nil
        }
    }
}

struct ToolBoxFocusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "查询或控制聚焦模式。",
        subcommands: [Status.self, Set.self]
    )

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "显示聚焦模式状态。")
        @OptionGroup var options: ToolBoxCLIConnectionOptions

        mutating func validate() throws { try options.validateValues() }
        mutating func run() throws { try runToolBoxRequest(.focusStatus, options: options) }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "修改聚焦模式开关或遮罩透明度。"
        )

        @Option(name: .long, help: ArgumentHelp("设置聚焦模式开关。", valueName: "true|false"))
        var enabled: ToolBoxBooleanValue?
        @Option(name: .long, help: "设置遮罩透明度百分比（20...85）。")
        var opacity: Int?
        @OptionGroup var options: ToolBoxCLIConnectionOptions

        mutating func validate() throws {
            try options.validateValues()
            guard enabled != nil || opacity != nil else {
                throw ValidationError("至少指定 --enabled 或 --opacity 中的一项。")
            }
            if let opacity, !(20...85).contains(opacity) {
                throw ValidationError("--opacity 必须在 20...85 之间。")
            }
        }

        mutating func run() throws {
            try runToolBoxRequest(
                .focusSet(ToolBoxFocusSetRequestDTO(
                    isEnabled: enabled?.boolValue,
                    opacityPercent: opacity
                )),
                options: options
            )
        }
    }
}

struct ToolBoxAudioCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audio",
        abstract: "查询音频应用和设备，或修改分应用音频规则。",
        subcommands: [Apps.self, Devices.self, Get.self, Set.self]
    )

    struct Apps: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "列出可配置的音频应用。")
        @OptionGroup var options: ToolBoxCLIConnectionOptions

        mutating func validate() throws { try options.validateValues() }
        mutating func run() throws { try runToolBoxRequest(.audioApps, options: options) }
    }

    struct Devices: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "列出音频输出设备。")
        @OptionGroup var options: ToolBoxCLIConnectionOptions

        mutating func validate() throws { try options.validateValues() }
        mutating func run() throws { try runToolBoxRequest(.audioDevices, options: options) }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "读取一个应用的音频规则。")

        @Option(
            name: .customLong("bundle-id"),
            help: ArgumentHelp("应用 Bundle ID。", valueName: "id")
        )
        var bundleID: String
        @OptionGroup var options: ToolBoxCLIConnectionOptions

        mutating func validate() throws {
            try options.validateValues()
            try validateBundleID(bundleID)
        }

        mutating func run() throws {
            try runToolBoxRequest(
                .audioGet(ToolBoxAudioGetRequestDTO(bundleID: bundleID)),
                options: options
            )
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "修改一个应用的一项音频规则。",
            discussion: "一次只能修改音量或输出设备；使用 system-default 恢复系统默认输出。"
        )

        @Option(
            name: .customLong("bundle-id"),
            help: ArgumentHelp("应用 Bundle ID。", valueName: "id")
        )
        var bundleID: String
        @Option(name: .long, help: "设置应用音量百分比（0...300）。")
        var volume: Int?
        @Option(
            name: .customLong("output-device"),
            help: ArgumentHelp("输出设备 UID，或 system-default。", valueName: "uid|system-default")
        )
        var outputDevice: String?
        @OptionGroup var options: ToolBoxCLIConnectionOptions

        mutating func validate() throws {
            try options.validateValues()
            try validateBundleID(bundleID)
            guard (volume == nil) != (outputDevice == nil) else {
                throw ValidationError("必须且只能指定 --volume 或 --output-device 中的一项。")
            }
            if let volume, !(0...300).contains(volume) {
                throw ValidationError("--volume 必须在 0...300 之间。")
            }
            if let outputDevice,
               outputDevice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--output-device 不能为空。")
            }
        }

        mutating func run() throws {
            let change: ToolBoxAudioChangeDTO
            if let volume {
                change = .volume(volume)
            } else if let outputDevice {
                let selection: ToolBoxAudioOutputSelectionDTO = outputDevice == "system-default"
                    ? .systemDefault
                    : .device(uid: outputDevice)
                change = .outputDevice(selection)
            } else {
                throw ValidationError("缺少音频设置。")
            }
            try runToolBoxRequest(
                .audioSet(ToolBoxAudioSetRequestDTO(bundleID: bundleID, change: change)),
                options: options
            )
        }
    }
}

private func validateBundleID(_ bundleID: String) throws {
    let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 255, !trimmed.contains(where: \.isWhitespace) else {
        throw ValidationError("--bundle-id 必须是非空且不含空白的 Bundle ID。")
    }
}

struct ToolBoxAwakeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "awake",
        abstract: "查询或控制防休眠。",
        subcommands: [Status.self, On.self, Off.self]
    )

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "显示防休眠状态。")
        @OptionGroup var options: ToolBoxCLIConnectionOptions
        mutating func validate() throws { try options.validateValues() }
        mutating func run() throws {
            try runToolBoxRequest(.awake(ToolBoxToggleRequestDTO(action: .status)), options: options)
        }
    }

    struct On: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "开启防休眠。")
        @OptionGroup var options: ToolBoxCLIConnectionOptions
        mutating func validate() throws { try options.validateValues() }
        mutating func run() throws {
            try runToolBoxRequest(.awake(ToolBoxToggleRequestDTO(action: .on)), options: options)
        }
    }

    struct Off: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "关闭防休眠。")
        @OptionGroup var options: ToolBoxCLIConnectionOptions
        mutating func validate() throws { try options.validateValues() }
        mutating func run() throws {
            try runToolBoxRequest(.awake(ToolBoxToggleRequestDTO(action: .off)), options: options)
        }
    }
}

struct ToolBoxLaunchAtLoginCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch-at-login",
        abstract: "查询或控制登录时启动。",
        subcommands: [Status.self, On.self, Off.self]
    )

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "显示登录时启动状态。")
        @OptionGroup var options: ToolBoxCLIConnectionOptions
        mutating func validate() throws { try options.validateValues() }
        mutating func run() throws {
            try runToolBoxRequest(.launchAtLogin(ToolBoxToggleRequestDTO(action: .status)), options: options)
        }
    }

    struct On: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "开启登录时启动。")
        @OptionGroup var options: ToolBoxCLIConnectionOptions
        mutating func validate() throws { try options.validateValues() }
        mutating func run() throws {
            try runToolBoxRequest(.launchAtLogin(ToolBoxToggleRequestDTO(action: .on)), options: options)
        }
    }

    struct Off: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "关闭登录时启动。")
        @OptionGroup var options: ToolBoxCLIConnectionOptions
        mutating func validate() throws { try options.validateValues() }
        mutating func run() throws {
            try runToolBoxRequest(.launchAtLogin(ToolBoxToggleRequestDTO(action: .off)), options: options)
        }
    }
}

struct ToolBoxInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "把当前 CLI 安装到 ~/.local/bin/toolbox。"
    )

    @OptionGroup var options: ToolBoxCLIOutputOptions

    mutating func run() throws {
        let renderer = ToolBoxCLIResponseRenderer()
        let writer = ToolBoxCLIWriter()
        let rendered: ToolBoxCLIRenderedOutput
        do {
            rendered = renderer.renderInstallResult(
                try ToolBoxCLIInstallManager().install(),
                asJSON: options.json
            )
        } catch {
            rendered = renderer.renderInstallError(error, asJSON: options.json)
        }
        writer.writeStandardOutput(rendered.standardOutput)
        writer.writeStandardError(rendered.standardError)
        if rendered.exitStatus != ToolBoxCLIExitStatus.success {
            throw ExitCode(rendered.exitStatus)
        }
    }
}

struct ToolBoxUninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "删除由当前 CLI 创建的 ~/.local/bin/toolbox 链接。"
    )

    @OptionGroup var options: ToolBoxCLIOutputOptions

    mutating func run() throws {
        let renderer = ToolBoxCLIResponseRenderer()
        let writer = ToolBoxCLIWriter()
        let rendered: ToolBoxCLIRenderedOutput
        do {
            rendered = renderer.renderInstallResult(
                try ToolBoxCLIInstallManager().uninstall(),
                asJSON: options.json
            )
        } catch {
            rendered = renderer.renderInstallError(error, asJSON: options.json)
        }
        writer.writeStandardOutput(rendered.standardOutput)
        writer.writeStandardError(rendered.standardError)
        if rendered.exitStatus != ToolBoxCLIExitStatus.success {
            throw ExitCode(rendered.exitStatus)
        }
    }
}
