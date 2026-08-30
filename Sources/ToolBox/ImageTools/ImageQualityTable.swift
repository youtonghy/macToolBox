import Foundation

/// 压缩级别（1 = 最高质量 … 6 = 最小体积）到各编码器参数的映射。
///
/// 数值参考成熟实现（Zipic）的级别语义并针对 ImageIO 的
/// 0...1 质量刻度标定；WebP 沿用 0...100 刻度。
enum ImageQualityTable {
    static let validLevels = 1 ... 6
    static let defaultLevel = 3

    static func normalizeLevel(_ level: Int) -> Int {
        min(max(level, validLevels.lowerBound), validLevels.upperBound)
    }

    /// ImageIO `kCGImageDestinationLossyCompressionQuality`（0...1）。
    static func compressionQuality(level: Int) -> Double {
        switch normalizeLevel(level) {
        case 1: return 0.92
        case 2: return 0.85
        case 3: return 0.75
        case 4: return 0.65
        case 5: return 0.55
        default: return 0.45
        }
    }

    /// libwebp 质量刻度（0...100）。
    static func webpQuality(level: Int) -> Float {
        Float(compressionQuality(level: level) * 100)
    }

    /// libwebp 编码努力程度（0...6）；4 是速度/压缩比的良好折中。
    static let webpEffort: Int32 = 4

    /// TIFF 重压缩使用的压缩方案（8 = ZIP/deflate，压缩率优于 LZW 且被现代解析器广泛支持）。
    static let tiffCompressionScheme: Int = 8
}
