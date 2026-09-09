import Foundation
import ToolBoxControlProtocol

// image.process / image.rehash 命令的应用侧实现。
// 由 ToolBoxCommandRouter 分发；压缩与换 Hash 走 ToolBoxCore 的
// ImagePipeline / ImageHashChanger。
extension ToolBoxCommandRouter {
    /// 单次命令最多处理的文件数（防止响应体与内存失控）。
    static let imageMaxInputFiles = 1_000
    /// 结果 DTO 列表截断阈值（约 200B/项，800 项远低于 1MiB 响应上限）。
    static let imageMaxResponseItems = 800

    func handleImageProcess(_ payload: ToolBoxImageProcessRequestDTO) async throws -> ToolBoxControlResult {
        let urls = try ImageFileCollector.collect(
            paths: payload.paths,
            recursive: payload.recursive ?? true
        )
        guard !urls.isEmpty else {
            throw ToolBoxImageCommandError.noSupportedImages
        }
        guard urls.count <= Self.imageMaxInputFiles else {
            throw ToolBoxImageCommandError.tooManyFiles(count: urls.count, limit: Self.imageMaxInputFiles)
        }

        let naming: ImageOutputNaming
        if payload.naming == "suffix" {
            naming = .suffix(payload.suffix ?? ImageOutputNaming.defaultSuffix)
        } else {
            naming = .overwrite
        }

        let options = ImageJobOptions(
            level: payload.level ?? ImageQualityTable.defaultLevel,
            outputFormat: payload.format.flatMap(Self.parseFormat),
            maxDimension: payload.maxDimension,
            stripMetadata: payload.stripMetadata ?? false,
            naming: naming
        )

        let results = await ImagePipeline.process(urls: urls, options: options)
        let items = results.map(Self.makeOutcomeDTO)
        let saved = results.reduce(0) { $0 + $1.savedBytes }
        let truncated = max(0, items.count - Self.imageMaxResponseItems)
        return .imageProcess(ToolBoxImageProcessResultDTO(
            items: Array(items.prefix(Self.imageMaxResponseItems)),
            totalBytesSaved: saved,
            truncatedItemCount: truncated
        ))
    }

    func handleImageRehash(_ payload: ToolBoxImageRehashRequestDTO) async throws -> ToolBoxControlResult {
        let urls = try ImageFileCollector.collect(
            paths: payload.paths,
            recursive: payload.recursive ?? true
        )
        guard !urls.isEmpty else {
            throw ToolBoxImageCommandError.noSupportedImages
        }
        guard urls.count <= Self.imageMaxInputFiles else {
            throw ToolBoxImageCommandError.tooManyFiles(count: urls.count, limit: Self.imageMaxInputFiles)
        }
        let results = await ImageHashChanger.rehash(urls: urls)
        let items = results.map(Self.makeRehashDTO)
        let truncated = max(0, items.count - Self.imageMaxResponseItems)
        return .imageRehash(ToolBoxImageRehashResultDTO(
            items: Array(items.prefix(Self.imageMaxResponseItems)),
            truncatedItemCount: truncated
        ))
    }

    // MARK: - 映射

    private static func parseFormat(_ raw: String) -> ImageFormat? {
        switch raw.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "png": return .png
        case "webp": return .webp
        case "avif": return .avif
        case "heic", "heif": return .heic
        case "tif", "tiff": return .tiff
        default: return nil
        }
    }

    private static func makeOutcomeDTO(_ result: ImageJobResult) -> ToolBoxImageOutcomeDTO {
        switch result.outcome {
        case let .replaced(original, output, format):
            return ToolBoxImageOutcomeDTO(
                source: result.source.path,
                kind: .replaced,
                originalBytes: original,
                resultBytes: output,
                outputFormat: format.rawValue
            )
        case let .converted(source, target, original, output, format):
            return ToolBoxImageOutcomeDTO(
                source: source.path,
                kind: .converted,
                target: target.path,
                originalBytes: original,
                resultBytes: output,
                outputFormat: format.rawValue
            )
        case let .savedAs(target, original, output, format):
            return ToolBoxImageOutcomeDTO(
                source: result.source.path,
                kind: .savedAs,
                target: target.path,
                originalBytes: original,
                resultBytes: output,
                outputFormat: format.rawValue
            )
        case let .sourceRetained(target, original, output, format, detail):
            return ToolBoxImageOutcomeDTO(
                source: result.source.path, kind: .savedAs, target: target.path,
                originalBytes: original, resultBytes: output, outputFormat: format.rawValue, detail: detail
            )
        case let .noBenefit(original, candidate, detail):
            return ToolBoxImageOutcomeDTO(
                source: result.source.path,
                kind: .noBenefit,
                originalBytes: original,
                resultBytes: candidate,
                detail: detail
            )
        case let .unsupported(detail):
            return ToolBoxImageOutcomeDTO(
                source: result.source.path,
                kind: .unsupported,
                detail: detail
            )
        case let .failed(detail):
            return ToolBoxImageOutcomeDTO(
                source: result.source.path,
                kind: .failed,
                detail: detail
            )
        }
    }

    private static func makeRehashDTO(_ result: ImageHashResult) -> ToolBoxImageRehashOutcomeDTO {
        switch result.outcome {
        case let .replaced(before, after, _):
            return ToolBoxImageRehashOutcomeDTO(
                source: result.source.path,
                kind: .replaced,
                before: makeHashesDTO(before),
                after: makeHashesDTO(after)
            )
        case let .unsupported(detail):
            return ToolBoxImageRehashOutcomeDTO(
                source: result.source.path,
                kind: .unsupported,
                detail: detail
            )
        case let .failed(detail):
            return ToolBoxImageRehashOutcomeDTO(
                source: result.source.path,
                kind: .failed,
                detail: detail
            )
        }
    }

    private static func makeHashesDTO(_ hashes: ImageFileHashes) -> ToolBoxImageHashesDTO {
        ToolBoxImageHashesDTO(md5: hashes.md5, sha1: hashes.sha1, sha256: hashes.sha256)
    }
}

enum ToolBoxImageCommandError: LocalizedError {
    case noSupportedImages
    case tooManyFiles(count: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case .noSupportedImages:
            return "输入路径中未找到受支持的图像文件（jpg/png/heic/tiff/webp/avif/gif）。"
        case let .tooManyFiles(count, limit):
            return "单次命令最多处理 \(limit) 个文件（本次展开 \(count) 个），请分批执行。"
        }
    }
}
