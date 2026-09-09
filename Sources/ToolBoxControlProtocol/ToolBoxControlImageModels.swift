import Foundation

// MARK: - 压缩 / 转换

public struct ToolBoxImageProcessRequestDTO: Codable, Equatable, Sendable {
    /// 输入文件或目录路径（相对路径按发起方工作目录展开）。
    public let paths: [String]
    /// 压缩级别 1...6；缺省用应用默认（3）。
    public let level: Int?
    /// 输出格式（jpeg|png|webp|avif|heic|tiff）；缺省保持原格式。
    public let format: String?
    /// 最长边像素上限；缺省不缩放。
    public let maxDimension: Int?
    /// 剥离元数据；缺省保留。
    public let stripMetadata: Bool?
    /// 输出命名："overwrite"（默认）或 "suffix"。
    public let naming: String?
    /// naming == "suffix" 时的后缀（默认 "-min"）。
    public let suffix: String?
    /// 输入含目录时是否递归展开。
    public let recursive: Bool?

    public init(
        paths: [String],
        level: Int? = nil,
        format: String? = nil,
        maxDimension: Int? = nil,
        stripMetadata: Bool? = nil,
        naming: String? = nil,
        suffix: String? = nil,
        recursive: Bool? = nil
    ) {
        self.paths = paths
        self.level = level
        self.format = format
        self.maxDimension = maxDimension
        self.stripMetadata = stripMetadata
        self.naming = naming
        self.suffix = suffix
        self.recursive = recursive
    }
}

public enum ToolBoxImageOutcomeKind: String, Codable, Sendable {
    case replaced
    case savedAs = "saved-as"
    case converted
    case noBenefit = "no-benefit"
    case unsupported
    case failed
}

public struct ToolBoxImageOutcomeDTO: Codable, Equatable, Sendable {
    public let source: String
    public let kind: ToolBoxImageOutcomeKind
    public let target: String?
    public let originalBytes: Int
    public let resultBytes: Int
    public let outputFormat: String?
    public let detail: String?

    public init(
        source: String,
        kind: ToolBoxImageOutcomeKind,
        target: String? = nil,
        originalBytes: Int = 0,
        resultBytes: Int = 0,
        outputFormat: String? = nil,
        detail: String? = nil
    ) {
        self.source = source
        self.kind = kind
        self.target = target
        self.originalBytes = originalBytes
        self.resultBytes = resultBytes
        self.outputFormat = outputFormat
        self.detail = detail
    }
}

public struct ToolBoxImageProcessResultDTO: Codable, Equatable, Sendable {
    public let items: [ToolBoxImageOutcomeDTO]
    /// 原件与产物的字节差之和；负值表示转换等操作使产物增大。
    public let totalBytesSaved: Int
    /// 结果列表超出传输上限被截断的数量（0 = 未截断）。
    public let truncatedItemCount: Int

    public init(
        items: [ToolBoxImageOutcomeDTO],
        totalBytesSaved: Int,
        truncatedItemCount: Int = 0
    ) {
        self.items = items
        self.totalBytesSaved = totalBytesSaved
        self.truncatedItemCount = truncatedItemCount
    }
}

// MARK: - 换 Hash

public struct ToolBoxImageRehashRequestDTO: Codable, Equatable, Sendable {
    public let paths: [String]
    public let recursive: Bool?

    public init(paths: [String], recursive: Bool? = nil) {
        self.paths = paths
        self.recursive = recursive
    }
}

public struct ToolBoxImageHashesDTO: Codable, Equatable, Sendable {
    public let md5: String
    public let sha1: String
    public let sha256: String

    public init(md5: String, sha1: String, sha256: String) {
        self.md5 = md5
        self.sha1 = sha1
        self.sha256 = sha256
    }
}

public struct ToolBoxImageRehashOutcomeDTO: Codable, Equatable, Sendable {
    public let source: String
    public let kind: ToolBoxImageOutcomeKind
    public let before: ToolBoxImageHashesDTO?
    public let after: ToolBoxImageHashesDTO?
    public let detail: String?

    public init(
        source: String,
        kind: ToolBoxImageOutcomeKind,
        before: ToolBoxImageHashesDTO? = nil,
        after: ToolBoxImageHashesDTO? = nil,
        detail: String? = nil
    ) {
        self.source = source
        self.kind = kind
        self.before = before
        self.after = after
        self.detail = detail
    }
}

public struct ToolBoxImageRehashResultDTO: Codable, Equatable, Sendable {
    public let items: [ToolBoxImageRehashOutcomeDTO]
    /// 结果列表超出传输上限被截断的数量（0 = 未截断）。
    public let truncatedItemCount: Int

    public init(items: [ToolBoxImageRehashOutcomeDTO], truncatedItemCount: Int = 0) {
        self.items = items
        self.truncatedItemCount = truncatedItemCount
    }
}
