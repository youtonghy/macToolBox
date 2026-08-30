import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import ToolBoxCore

/// 图像工具测试共享的 fixture 生成器：
/// 程序化绘制图像并编码为各格式，避免仓库内提交二进制文件。
enum ImageFixtureFactory {
    /// 生成一张带渐变与色块的 RGBA 图像（可压缩内容，且各处像素不同）。
    static func makeImage(width: Int = 240, height: Int = 160) -> CGImage? {
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let offset = y * bytesPerRow + x * 4
                buffer[offset] = UInt8((x * 255) / max(1, width - 1))
                buffer[offset + 1] = UInt8((y * 255) / max(1, height - 1))
                buffer[offset + 2] = UInt8(((x + y) % 128) * 2)
                buffer[offset + 3] = 255
            }
        }
        return buffer.withUnsafeBytes { pointer -> CGImage? in
            guard let base = pointer.baseAddress else { return nil }
            guard let context = CGContext(
                data: UnsafeMutableRawPointer(mutating: base),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: UInt32(CGImageAlphaInfo.premultipliedLast.rawValue)
                    | UInt32(CGImageByteOrderInfo.order32Big.rawValue)
            ) else { return nil }
            return context.makeImage()
        }
    }

    /// 把 CGImage 编码为指定格式（ImageIO 支持的格式）。
    static func encode(_ image: CGImage, format: ImageFormat, quality: Double = 0.9) -> Data? {
        guard let identifier = format.imageIOTypeIdentifier else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, identifier as CFString, 1, nil
        ) else { return nil }
        var properties: [CFString: Any] = [:]
        if format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// 编码为 WebP（走 libwebp 编码器）。
    static func encodeWebP(_ image: CGImage, quality: Float = 85) throws -> Data {
        try WebPEncoder.encodeLossy(image, quality: quality)
    }

    /// 写入临时目录并返回 URL。
    static func writeTemporary(_ data: Data, extension: String, name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolbox-image-tests-\(name).\(`extension`)")
        try data.write(to: url)
        return url
    }

    /// 生成并落盘一张指定格式的渐变图。
    static func makeFixtureFile(format: ImageFormat, width: Int = 240, height: Int = 160) throws -> URL {
        guard let image = makeImage(width: width, height: height) else {
            throw XCTSkip("无法生成测试图像")
        }
        let data: Data
        switch format {
        case .webp:
            data = try encodeWebP(image)
        default:
            guard let encoded = encode(image, format: format) else {
                throw XCTSkip("当前系统不支持编码 \(format.rawValue)")
            }
            data = encoded
        }
        return try writeTemporary(data, extension: format.preferredFilenameExtension)
    }
}
