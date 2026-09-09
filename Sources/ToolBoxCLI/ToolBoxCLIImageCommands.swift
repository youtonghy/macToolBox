import ArgumentParser
import Foundation
import ToolBoxControlProtocol

/// 图像命令的请求发送：批量处理大文件容易超过默认 10 秒等待，
/// 将最短等待提升到协议上限 300 秒（用户显式传入更大值不受影响，
/// 但受现有校验约束最大也是 300）。
private func runImageToolBoxRequest(
    _ request: ToolBoxControlRequest,
    options: ToolBoxCLIConnectionOptions
) throws {
    var connectionOptions = options
    connectionOptions.timeout = max(options.timeout, 300)
    try runToolBoxRequest(request, options: connectionOptions)
}

/// toolbox image compress|convert|rehash —— 图像压缩 / 格式转换 / 换 Hash。
struct ToolBoxImageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image",
        abstract: "批量压缩、转换图像格式或更换文件哈希。",
        discussion: "纯压缩结果不小于原文件时保留原件；显式转换、缩放或剥离元数据允许体积增加；换 Hash 不重编码，像素逐位不变。控制命令由正在运行的 ToolBox 应用执行。",
        subcommands: [Compress.self, Convert.self, Rehash.self]
    )

    // MARK: - compress

    struct Compress: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "compress",
            abstract: "压缩图像（可选转换格式与缩放）。"
        )

        @Option(name: .long, help: "压缩级别 1...6（1 最高质量，6 最小体积；默认 3）。")
        var level: Int?

        @Option(
            name: .customLong("format"),
            help: ArgumentHelp(
                "输出格式 original|jpeg|png|webp|avif|heic|tiff（缺省 original 保持原格式）。",
                valueName: "fmt"
            )
        )
        var format: String?

        @Option(
            name: .customLong("max-dimension"),
            help: ArgumentHelp("最长边像素上限，超出时按比例缩小。", valueName: "px")
        )
        var maxDimension: Int?

        @Flag(name: .customLong("strip-metadata"), help: "剥离 EXIF/XMP/ICC/DPI 元数据（默认保留）。")
        var stripMetadata = false

        @Option(
            name: .customLong("naming"),
            help: ArgumentHelp("输出命名 overwrite（默认，原地覆盖）或 suffix（加后缀另存）。", valueName: "mode")
        )
        var naming: String?

        @Option(
            name: .customLong("suffix"),
            help: ArgumentHelp("naming=suffix 时的后缀（默认 -min）。", valueName: "text")
        )
        var suffix: String?

        @Argument(help: ArgumentHelp("图像文件或目录（目录按支持扩展名展开）。", valueName: "path"))
        var paths: [String]

        @Flag(
            name: .customLong("no-recursive"),
            help: "输入含目录时仅处理顶层文件。"
        )
        var noRecursive = false

        @OptionGroup var options: ToolBoxCLIConnectionOptions

        mutating func validate() throws {
            try options.validateValues()
            try ToolBoxImageCommand.validateCommon(
                paths: paths, level: level, format: format,
                maxDimension: maxDimension, naming: naming, suffix: suffix,
                formatOptional: true
            )
        }

        mutating func run() throws {
            try runImageToolBoxRequest(
                .imageProcess(ToolBoxImageProcessRequestDTO(
                    paths: ToolBoxImageCommand.expandPaths(paths),
                    level: level,
                    format: format?.lowercased() == "original" ? nil : format,
                    maxDimension: maxDimension,
                    stripMetadata: stripMetadata,
                    naming: naming,
                    suffix: suffix,
                    recursive: !noRecursive
                )),
                options: options
            )
        }
    }

    // MARK: - convert

    struct Convert: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "convert",
            abstract: "转换图像格式（必须指定 --format，允许输出体积增加）。"
        )

        @Option(
            name: .customLong("format"),
            help: ArgumentHelp("目标格式 jpeg|png|webp|avif|heic|tiff。", valueName: "fmt")
        )
        var format: String

        @Option(name: .long, help: "质量级别 1...6（默认 3）。")
        var level: Int?

        @Option(
            name: .customLong("max-dimension"),
            help: ArgumentHelp("最长边像素上限。", valueName: "px")
        )
        var maxDimension: Int?

        @Flag(name: .customLong("strip-metadata"), help: "剥离元数据。")
        var stripMetadata = false

        @Option(
            name: .customLong("naming"),
            help: ArgumentHelp("输出命名 overwrite（默认）或 suffix。", valueName: "mode")
        )
        var naming: String?

        @Option(
            name: .customLong("suffix"),
            help: ArgumentHelp("naming=suffix 时的后缀（默认 -min）。", valueName: "text")
        )
        var suffix: String?

        @Argument(help: ArgumentHelp("图像文件或目录。", valueName: "path"))
        var paths: [String]

        @Flag(
            name: .customLong("no-recursive"),
            help: "输入含目录时仅处理顶层文件。"
        )
        var noRecursive = false

        @OptionGroup var options: ToolBoxCLIConnectionOptions

        mutating func validate() throws {
            try options.validateValues()
            try ToolBoxImageCommand.validateCommon(
                paths: paths, level: level, format: format,
                maxDimension: maxDimension, naming: naming, suffix: suffix,
                formatOptional: false
            )
        }

        mutating func run() throws {
            try runImageToolBoxRequest(
                .imageProcess(ToolBoxImageProcessRequestDTO(
                    paths: ToolBoxImageCommand.expandPaths(paths),
                    level: level,
                    format: format,
                    maxDimension: maxDimension,
                    stripMetadata: stripMetadata,
                    naming: naming,
                    suffix: suffix,
                    recursive: !noRecursive
                )),
                options: options
            )
        }
    }

    // MARK: - rehash

    struct Rehash: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rehash",
            abstract: "更换图像文件哈希（不重编码，像素逐位不变；可重复执行）。"
        )

        @Argument(help: ArgumentHelp("图像文件或目录。", valueName: "path"))
        var paths: [String]

        @Flag(
            name: .customLong("no-recursive"),
            help: "输入含目录时仅处理顶层文件。"
        )
        var noRecursive = false

        @OptionGroup var options: ToolBoxCLIConnectionOptions

        mutating func validate() throws {
            try options.validateValues()
            guard !paths.isEmpty else {
                throw ValidationError("至少提供一个图像文件或目录。")
            }
        }

        mutating func run() throws {
            try runImageToolBoxRequest(
                .imageRehash(ToolBoxImageRehashRequestDTO(
                    paths: ToolBoxImageCommand.expandPaths(paths),
                    recursive: !noRecursive
                )),
                options: options
            )
        }
    }

    // MARK: - 共享工具

    /// 相对路径按 CLI 发起方的工作目录展开为绝对路径
    ///（控制命令由 App 进程执行，其工作目录与 CLI 不同）。
    fileprivate static func expandPaths(_ paths: [String]) -> [String] {
        let workingDirectory = FileManager.default.currentDirectoryPath
        return paths.map { path in
            let expanded = (path as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                return expanded
            }
            return (workingDirectory as NSString).appendingPathComponent(expanded)
        }
    }

    fileprivate static func validateCommon(
        paths: [String],
        level: Int?,
        format: String?,
        maxDimension: Int?,
        naming: String?,
        suffix: String?,
        formatOptional: Bool
    ) throws {
        guard !paths.isEmpty else {
            throw ValidationError("至少提供一个图像文件或目录。")
        }
        if let level, !(1 ... 6).contains(level) {
            throw ValidationError("--level 必须在 1...6 之间。")
        }
        if let format {
            let allowed = ["original", "jpeg", "png", "webp", "avif", "heic", "tiff"]
            if !allowed.contains(format.lowercased()) || (!formatOptional && format.lowercased() == "original") {
                throw ValidationError("--format 必须是 \(formatOptional ? "original|" : "")jpeg/png/webp/avif/heic/tiff 之一。")
            }
        } else if !formatOptional {
            throw ValidationError("convert 必须指定 --format。")
        }
        if let maxDimension, maxDimension <= 0 {
            throw ValidationError("--max-dimension 必须是正整数。")
        }
        if let naming, naming != "overwrite", naming != "suffix" {
            throw ValidationError("--naming 必须是 overwrite 或 suffix。")
        }
        if let suffix, suffix.isEmpty {
            throw ValidationError("--suffix 不能为空。")
        }
    }
}
