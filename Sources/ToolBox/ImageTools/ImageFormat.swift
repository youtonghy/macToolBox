import Foundation
import UniformTypeIdentifiers

/// 图像格式识别与元数据。
///
/// 探测以文件魔数为准，扩展名仅作兜底提示；
/// 支持的格式集合与 `ImagePipeline` 的能力矩阵保持一致。
enum ImageFormat: String, CaseIterable, Sendable {
    case jpeg
    case png
    case heic
    case tiff
    case webp
    case avif
    case gif

    /// 基于魔数的格式探测（读取文件头，最多 32 字节）。
    static func detect(url: URL) -> ImageFormat? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 32), head.count >= 12 else { return nil }
        return detect(dataPrefix: head)
    }

    /// 基于数据前缀的格式探测。
    static func detect(dataPrefix: Data) -> ImageFormat? {
        func has(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            guard dataPrefix.count >= offset + bytes.count else { return false }
            return Data(bytes).elementsEqual(dataPrefix[offset ..< offset + bytes.count])
        }
        if has([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if has([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if has([0x47, 0x49, 0x46, 0x38]) { return .gif } // GIF8
        if has([0x49, 0x49, 0x2A, 0x00]) || has([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if has([0x52, 0x49, 0x46, 0x46]) && dataPrefix.count >= 12 {
            let form = String(data: dataPrefix[8 ..< 12], encoding: .ascii)
            if form == "WEBP" { return .webp }
        }
        if has([0x66, 0x74, 0x79, 0x70], at: 4) {
            // ISO 基础媒体容器：区分 HEIC/AVIF 与其他 brand。
            guard dataPrefix.count >= 12 else { return nil }
            let brand = String(data: dataPrefix[8 ..< 12], encoding: .ascii) ?? ""
            switch brand {
            case "avif", "avis": return .avif
            case "heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1":
                return .heic
            default: return nil
            }
        }
        return nil
    }

    /// 输出用统一扩展名。
    var preferredFilenameExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .heic: return "heic"
        case .tiff: return "tiff"
        case .webp: return "webp"
        case .avif: return "avif"
        case .gif: return "gif"
        }
    }

    /// CGImageDestination 可直接编码的 UTType；WebP 需要走 libwebp 编码器。
    var imageIOTypeIdentifier: String? {
        switch self {
        case .jpeg: return UTType.jpeg.identifier
        case .png: return UTType.png.identifier
        case .heic: return UTType.heic.identifier
        case .tiff: return UTType.tiff.identifier
        case .avif: return "public.avif"
        case .gif: return UTType.gif.identifier
        case .webp: return nil // 系统 ImageIO 不支持 WebP 编码，使用 WebPEncoder。
        }
    }

    /// 有损格式（编码质量参数有意义）。
    var isLossy: Bool {
        switch self {
        case .jpeg, .heic, .avif, .webp: return true
        case .png, .tiff, .gif: return false
        }
    }

    /// 无损容器格式：转 WebP 时默认采用无损编码，避免画质退化。
    var isLosslessContainer: Bool {
        switch self {
        case .png, .tiff: return true
        case .jpeg, .heic, .webp, .avif, .gif: return false
        }
    }

    /// 解码支持的最低系统版本说明（运行时能力探测在 ImageCapabilities 中完成）。
    var decodeLimitation: String? {
        switch self {
        case .avif: return "AVIF 解码需要 macOS 13 或更高版本。"
        case .webp: return nil
        default: return nil
        }
    }
}
