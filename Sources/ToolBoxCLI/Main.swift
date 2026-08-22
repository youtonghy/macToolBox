import ArgumentParser
import Foundation

@main
struct ToolBoxCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "toolbox",
        abstract: "通过命令行查询和控制 ToolBox 系统功能。",
        discussion: """
        控制命令由正在运行的 ToolBox 应用执行。除非指定 --no-launch，
        ToolBox 未运行时会在后台启动并等待控制端就绪。
        """,
        version: ToolBoxCLIVersion.current,
        subcommands: [
            ToolBoxStatusCommand.self,
            ToolBoxDisplayCommand.self,
            ToolBoxFocusCommand.self,
            ToolBoxAudioCommand.self,
            ToolBoxAwakeCommand.self,
            ToolBoxLaunchAtLoginCommand.self,
            ToolBoxInstallCommand.self,
            ToolBoxUninstallCommand.self,
        ]
    )
}

enum ToolBoxCLIVersion {
    static var current: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "DEV0.0.0"
    }
}
