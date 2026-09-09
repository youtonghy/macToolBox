import CryptoKit
import Foundation
import ImageIO
import Security

/// 换 Hash 结果中的哈希集合。
struct ImageFileHashes: Sendable, Equatable {
    let md5: String
    let sha1: String
    let sha256: String

    init(data: Data) {
        md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        sha1 = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var displayLine: String {
        "MD5 \(md5)\nSHA-1 \(sha1)\nSHA-256 \(sha256)"
    }
}

enum ImageHashOutcome: Sendable, Equatable {
    case replaced(before: ImageFileHashes, after: ImageFileHashes, bytes: Int)
    case unsupported(detail: String)
    case failed(detail: String)
}

struct ImageHashResult: Sendable, Equatable {
    let source: URL
    let outcome: ImageHashOutcome
}

/// 换 Hash：不重编码、零视觉差异地改变文件哈希。
///
/// 原理：在每种格式的"解析器保证跳过"的位置注入带随机载荷的
/// 合法结构（JPEG COM 段 / PNG tEXt 块 / WebP JUNK chunk /
/// GIF Comment Extension / HEIC-AVIF free box / TIFF 尾部注释），
/// 重复执行时先剥离自己此前注入的内容再注入新值，保证幂等可控。
enum ImageHashChanger {
    enum HashChangeError: Error, CustomStringConvertible {
        case malformed(String)
        case validationFailed(String)
        case writeFailed(String)

        var description: String {
            switch self {
            case let .malformed(detail): return "文件结构异常：\(detail)"
            case let .validationFailed(detail): return "换 Hash 后校验失败：\(detail)"
            case let .writeFailed(detail): return "写入失败：\(detail)"
            }
        }
    }

    /// 各格式 Mutator 注入内容携带的统一标记，
    /// 用于剥离旧注入、避免文件随反复换 Hash 无限增长。
    static let injectionMarker = Data("TOOLBOX-HASH-V1:".utf8)

    static func supports(format: ImageFormat) -> Bool {
        true // 目前支持的七种格式全部实现
    }

    // MARK: - 单文件

    static func rehash(url: URL, beforeCommit: () throws -> Void = {}) -> ImageHashResult {
        do {
            let outcome = try rehashOrThrow(url: url, beforeCommit: beforeCommit)
            return ImageHashResult(source: url, outcome: outcome)
        } catch is CancellationError {
            return ImageHashResult(source: url, outcome: .failed(detail: "已取消。"))
        } catch let error as HashChangeError {
            return ImageHashResult(source: url, outcome: .failed(detail: error.description))
        } catch {
            return ImageHashResult(source: url, outcome: .failed(detail: error.localizedDescription))
        }
    }

    static func rehashOrThrow(url: URL, beforeCommit: () throws -> Void = {}) throws -> ImageHashOutcome {
        try Task.checkCancellation()
        guard let format = ImageFormat.detect(url: url) else {
            return .unsupported(detail: "无法识别的图像格式。")
        }
        let original = try Data(contentsOf: url, options: .mappedIfSafe)
        let before = ImageFileHashes(data: original)

        // 像素预算：与压缩管线一致，避免常驻进程对超大图做双份 RGBA 渲染。
        if let pixelCount = Self.estimatedPixelCount(original) {
            guard pixelCount <= ImagePipeline.maxPixelsPerImage else {
                return .unsupported(
                    detail: "图像超过单图 \(ImagePipeline.maxPixelsPerImage / 1_000_000)MP 上限，已跳过。"
                )
            }
        }

        try Task.checkCancellation()
        let mutated = try mutate(data: original, format: format)
        try Task.checkCancellation()
        try validateVisualEquality(original: original, mutated: mutated, format: format)

        let after = ImageFileHashes(data: mutated)
        precondition(before != after, "换 Hash 后摘要未变化")

        try beforeCommit()
        try Task.checkCancellation()
        try AtomicFileReplacer.replace(original: url, data: mutated, tempExtension: "toolbox-rehash")
        return .replaced(before: before, after: after, bytes: mutated.count)
    }

    /// 从图像数据估算像素数（失败返回 nil，交由后续解码校验把关）。
    private static func estimatedPixelCount(_ data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return width * height
    }

    /// 批量入口（目录由调用方展开）。
    static func rehash(
        urls: [URL],
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async -> [ImageHashResult] {
        guard !urls.isEmpty, !Task.isCancelled else { return [] }
        let width = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))
        var results: [ImageHashResult] = []
        results.reserveCapacity(urls.count)
        var completed = 0
        var index = 0
        while index < urls.count {
            if Task.isCancelled { break }
            let chunkEnd = min(index + width, urls.count)
            let chunk = Array(urls[index ..< chunkEnd])
            let collected: [Int: ImageHashResult] = await withTaskGroup(
                of: (Int, ImageHashResult).self
            ) { group in
                for (offset, url) in chunk.enumerated() {
                    group.addTask { (offset, rehash(url: url)) }
                }
                var partial: [Int: ImageHashResult] = [:]
                for await (offset, result) in group { partial[offset] = result }
                return partial
            }
            for offset in 0 ..< chunk.count {
                if let result = collected[offset] {
                    results.append(result)
                    completed += 1
                    progress?(completed, urls.count)
                }
            }
            index = chunkEnd
        }
        return results
    }

    // MARK: - 变异与校验

    static func mutate(data: Data, format: ImageFormat) throws -> Data {
        let payload = Self.injectionMarker + Self.randomPayload()
        switch format {
        case .jpeg: return try JPEGHashMutator.mutate(data, payload: payload)
        case .png: return try PNGHashMutator.mutate(data, payload: payload)
        case .webp: return try WebPHashMutator.mutate(data, payload: payload)
        case .gif: return try GIFHashMutator.mutate(data, payload: payload)
        case .heic, .avif: return try BMFFHashMutator.mutate(data, payload: payload)
        case .tiff: return try TIFFHashMutator.mutate(data, payload: payload)
        }
    }

    /// 生成 16...32 字节随机载荷（注入内容每次都不同 → 哈希每次都变）。
    static func randomPayload(byteCount: Int = 24) -> Data {
        let count = max(8, min(64, byteCount))
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // 系统随机源不可用时退化为 UUID 派生熵。
            let fallback = UUID().uuidString.data(using: .utf8)!
            var mixed = Data()
            while mixed.count < count { mixed.append(fallback) }
            return mixed.prefix(count)
        }
        // 仅使用可打印字符，避免载荷被当成损坏数据。
        return Data(bytes.map { byte in
            0x21 + (byte % 0x5E) // '!' ... '~'
        })
    }

    /// 安全网：换 Hash 后必须仍可解码，且渲染像素与原件逐位一致。
    static func validateVisualEquality(original: Data, mutated: Data, format: ImageFormat) throws {
        guard let mutatedSource = CGImageSourceCreateWithData(mutated as CFData, nil),
              CGImageSourceGetCount(mutatedSource) > 0
        else {
            throw HashChangeError.validationFailed("产物无法被系统解码。")
        }
        guard let originalSource = CGImageSourceCreateWithData(original as CFData, nil),
              CGImageSourceGetCount(originalSource) > 0,
              CGImageSourceGetCount(originalSource) == CGImageSourceGetCount(mutatedSource)
        else {
            throw HashChangeError.validationFailed("原件无法解码或产物帧数发生变化。")
        }
        for index in 0..<CGImageSourceGetCount(originalSource) {
            try Task.checkCancellation()
            let equal = autoreleasepool {
                guard let mutatedPixels = Self.renderPixelSignature(mutatedSource, index: index),
                      let originalPixels = Self.renderPixelSignature(originalSource, index: index) else { return false }
                return originalPixels == mutatedPixels
            }
            guard equal else {
                throw HashChangeError.validationFailed("产物像素与原件不一致，已放弃替换。")
            }
        }
    }

    /// 逐帧渲染，释放上一帧后再处理下一帧，保持内存预算。
    private static func renderPixelSignature(_ source: CGImageSource, index: Int) -> Data? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= ImagePipeline.maxPixelsPerImage / pixelHeight,
              let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var data = Data(count: width * height * 4)
        let ok = data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Bool in
            guard let base = buffer.baseAddress else { return false }
            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: UInt32(CGImageAlphaInfo.premultipliedLast.rawValue)
                    | UInt32(CGImageByteOrderInfo.order32Big.rawValue)
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? data : nil
    }

    // MARK: - 落地

    // 落地统一使用 AtomicFileReplacer.replace（保留权限与 xattr）。
}
