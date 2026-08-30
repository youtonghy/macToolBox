import Foundation
import ImageIO

/// 运行时编码能力探测。
///
/// AVIF 编码自 macOS 15 起可用；部署目标为 macOS 14，
/// 因此必须在运行时查询 `CGImageDestinationCopyTypeIdentifiers`
/// 而不是依赖编译期常量。WebP 编码经由内嵌 libwebp，恒可用。
enum ImageCapabilities {
    /// ImageIO 当前进程可写出的格式标识缓存（进程内有效）。
    private static let encodableTypeIdentifiers: Set<String> = {
        let identifiers = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return Set(identifiers)
    }()

    static func canImageIOEncode(_ format: ImageFormat) -> Bool {
        guard let identifier = format.imageIOTypeIdentifier else { return false }
        return encodableTypeIdentifiers.contains(identifier)
    }

    static var avifEncodingAvailable: Bool { canImageIOEncode(.avif) }

    /// 给定输出格式是否可用（含 WebP/libwebp 通道）。
    static func canEncode(_ format: ImageFormat) -> Bool {
        switch format {
        case .webp: return true
        default: return canImageIOEncode(format)
        }
    }

    /// 不可用时的用户可读原因（用于 UI 置灰提示与 CLI 报错）。
    static func unavailableReason(for format: ImageFormat) -> String? {
        if canEncode(format) { return nil }
        switch format {
        case .avif:
            return "此系统版本不支持 AVIF 编码，需要 macOS 15 或更高版本。"
        default:
            return "此系统版本不支持编码 \(format.rawValue.uppercased()) 格式。"
        }
    }
}
