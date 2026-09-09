import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import libwebp

/// 基于 libwebp 的 WebP 编码器。
///
/// 系统 ImageIO 不提供 WebP 编码（已在 macOS 14/26 实测确认），
/// 因此 WebP 输出统一走本编码器：
/// - 有损：`quality` 0...100
/// - 无损：`encodeLossless`（PNG/TIFF 等无损来源转换时默认使用，保证画质不退化）
enum WebPEncodeError: Error, CustomStringConvertible {
    case renderFailed
    case imageTooLarge(width: Int, height: Int)
    case encodeFailed(status: Int32)

    var description: String {
        switch self {
        case .renderFailed:
            return "无法将图像渲染为 RGBA 缓冲区。"
        case let .imageTooLarge(width, height):
            return "图像尺寸过大（\(width)×\(height)，上限 \(WebPEncoder.maximumDimension) 像素）。"
        case let .encodeFailed(status):
            return "WebP 编码失败（状态码 \(status)）。"
        }
    }
}

enum WebPEncoder {
    /// libwebp 单边上限 16383；超过即拒绝，避免静默失败。
    static let maximumDimension = 16_383

    // MARK: - 对外接口

    static func encodeLossy(_ image: CGImage, quality: Float, effort: Int32 = ImageQualityTable.webpEffort) throws -> Data {
        try encode(image, lossless: false, quality: quality, effort: effort)
    }

    static func encodeLossless(_ image: CGImage, effort: Int32 = ImageQualityTable.webpEffort) throws -> Data {
        try encode(image, lossless: true, quality: 100, effort: effort)
    }

    static func attachMetadata(_ chunks: [(String, Data)], to pixels: Data) throws -> Data {
        let mux = pixels.withUnsafeBytes { raw -> OpaquePointer? in
            var input = WebPData(bytes: raw.bindMemory(to: UInt8.self).baseAddress, size: raw.count)
            return WebPMuxCreate(&input, 1)
        }
        guard let mux else { throw WebPEncodeError.encodeFailed(status: -1) }
        defer { WebPMuxDelete(mux) }
        for (name, data) in chunks {
            let status = data.withUnsafeBytes { raw in
                var chunk = WebPData(bytes: raw.bindMemory(to: UInt8.self).baseAddress, size: raw.count)
                return WebPMuxSetChunk(mux, name, &chunk, 1)
            }
            guard status == WEBP_MUX_OK else { throw WebPEncodeError.encodeFailed(status: status.rawValue) }
        }
        var output = WebPData()
        defer { WebPDataClear(&output) }
        let status = WebPMuxAssemble(mux, &output)
        guard status == WEBP_MUX_OK, let bytes = output.bytes else {
            throw WebPEncodeError.encodeFailed(status: status.rawValue)
        }
        return Data(bytes: bytes, count: output.size)
    }

    // MARK: - 实现

    private static func encode(_ image: CGImage, lossless: Bool, quality: Float, effort: Int32) throws -> Data {
        var config = WebPConfig()
        guard WebPConfigPreset(&config, WebPPreset(WEBP_PRESET_DEFAULT.rawValue), quality) != 0 else {
            throw WebPEncodeError.encodeFailed(status: Int32(VP8_STATUS_INVALID_PARAM.rawValue))
        }
        config.lossless = lossless ? 1 : 0
        config.method = effort
        if lossless {
            config.exact = 1 // 保留全透明区域的 RGB 值
        }

        let rgba = try renderRGBA(image)
        defer { rgba.buffer.deallocate() }

        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else {
            throw WebPEncodeError.encodeFailed(status: Int32(VP8_STATUS_INVALID_PARAM.rawValue))
        }
        picture.width = Int32(image.width)
        picture.height = Int32(image.height)
        picture.use_argb = lossless ? 1 : 0

        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer {
            if writer.mem != nil { WebPMemoryWriterClear(&writer) }
            WebPPictureFree(&picture)
        }

        // writer 的指针必须在 WebPEncode 整个调用期间存活，
        // 因此用 withUnsafeMutablePointer 显式延长生命周期。
        let encoded: Data? = withUnsafeMutablePointer(to: &writer) { writerPointer in
            picture.writer = WebPMemoryWrite
            picture.custom_ptr = UnsafeMutableRawPointer(writerPointer)
            guard WebPPictureImportRGBA(&picture, rgba.buffer, Int32(rgba.bytesPerRow)) != 0 else {
                return nil
            }
            guard WebPEncode(&config, &picture) != 0 else {
                return nil
            }
            guard let memory = writerPointer.pointee.mem, writerPointer.pointee.size > 0 else {
                return nil
            }
            return Data(bytes: memory, count: writerPointer.pointee.size)
        }
        guard let encoded else {
            throw WebPEncodeError.encodeFailed(status: Int32(picture.error_code.rawValue))
        }
        return encoded
    }

    private struct RGBABuffer {
        let buffer: UnsafeMutableRawPointer
        let bytesPerRow: Int
    }

    /// 把 CGImage 渲染为"直通（非预乘）RGBA8888"缓冲区。
    private static func renderRGBA(_ image: CGImage) throws -> RGBABuffer {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension else {
            throw WebPEncodeError.imageTooLarge(width: width, height: height)
        }

        let bytesPerRow = width * 4
        let bufferSize = bytesPerRow * height
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 64)
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: bufferSize)

        guard let context = CGContext(
            data: buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: UInt32(CGImageAlphaInfo.premultipliedLast.rawValue)
                | UInt32(CGImageByteOrderInfo.order32Big.rawValue)
        ) else {
            buffer.deallocate()
            throw WebPEncodeError.renderFailed
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // CGContext 产出预乘 RGBA；libwebp 的 WebPPictureImportRGBA 需要直通 alpha。
        var info = vImage_Buffer(data: buffer, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow)
        vImageUnpremultiplyData_RGBA8888(&info, &info, vImage_Flags(kvImageDoNotTile))
        return RGBABuffer(buffer: buffer, bytesPerRow: bytesPerRow)
    }
}
