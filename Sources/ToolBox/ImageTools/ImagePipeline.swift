import CoreGraphics
import Foundation
import ImageIO

/// 单个压缩/转换任务的全部可配置项。
struct ImageJobOptions: Sendable, Equatable {
    /// 压缩级别 1...6（1 = 最高质量，6 = 最小体积）。
    var level: Int = ImageQualityTable.defaultLevel
    /// 输出格式；`nil` 表示保持原格式。
    var outputFormat: ImageFormat?
    /// 最长边像素上限；`nil` 表示不缩放。
    var maxDimension: Int?
    /// 剥离元数据（EXIF/XMP/ICC/DPI）；默认保留。
    var stripMetadata = false
    /// 输出命名策略：覆盖原文件，或加后缀另存。
    var naming: ImageOutputNaming = .overwrite

    init(
        level: Int = ImageQualityTable.defaultLevel,
        outputFormat: ImageFormat? = nil,
        maxDimension: Int? = nil,
        stripMetadata: Bool = false,
        naming: ImageOutputNaming = .overwrite
    ) {
        self.level = ImageQualityTable.normalizeLevel(level)
        self.outputFormat = outputFormat
        self.maxDimension = maxDimension
        self.stripMetadata = stripMetadata
        self.naming = naming
    }
}

enum ImageOutputNaming: Sendable, Equatable {
    /// 原地覆盖（同格式）；格式转换时写新扩展名文件并删除源文件（先写后删）。
    case overwrite
    /// 加后缀另存，如 `-min`：`photo.jpg` → `photo-min.jpg`。
    case suffix(String)

    static let defaultSuffix = "-min"
}

/// 单个文件的处理结果。
enum ImageOutcome: Sendable, Equatable {
    /// 原地替换成功（同格式）。
    case replaced(originalBytes: Int, resultBytes: Int, format: ImageFormat)
    /// 另存成功（后缀策略）。
    case savedAs(URL, originalBytes: Int, resultBytes: Int, format: ImageFormat)
    /// 格式转换 + 覆盖：写入 `target`（新扩展名）成功后已删除源文件。
    case converted(source: URL, target: URL, originalBytes: Int, resultBytes: Int, format: ImageFormat)
    /// 产物已保存，但源文件删除失败。
    case sourceRetained(target: URL, originalBytes: Int, resultBytes: Int, format: ImageFormat, detail: String)
    /// 无收益保护：结果不小于原文件，保留原件未动。
    case noBenefit(originalBytes: Int, candidateBytes: Int, detail: String)
    /// 格式/能力/内容不支持，未处理。
    case unsupported(detail: String)
    /// 处理失败，原件未动。
    case failed(detail: String)

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

struct ImageJobResult: Sendable, Equatable {
    let source: URL
    let outcome: ImageOutcome

    /// 成功项的节省字节数（无收益/失败为 0）。
    var savedBytes: Int {
        switch outcome {
        case let .replaced(original, result, _): return original - result
        case let .savedAs(_, original, result, _): return original - result
        case let .converted(_, _, original, result, _): return original - result
        case let .sourceRetained(_, original, result, _, _): return original - result
        default: return 0
        }
    }
}

/// 压缩 / 格式转换管线。
///
/// 流程：格式探测 → 输入安全检查（帧数/HDR/位深/像素预算）
/// → 解码（方向烘焙进像素，含可选缩放）→ 元数据策略 → 编码
/// （ImageIO 或 libwebp）→ 无收益保护 → 原子落地（保留权限与 xattr）。
///
/// 安全语义：
/// - 多帧（动图）拒绝处理，避免静默丢失帧；
/// - HDR/宽色域/>8bit/带增益图拒绝处理，避免静默降级并覆盖原件；
/// - 单图像素超预算拒绝，防止常驻进程 OOM；
/// - 取消：批量循环与任务组内检查 `Task.isCancelled`。
enum ImagePipeline {
    /// 资源预算：单图像素上限（RGBA ≈ 96MB）与批量并发宽度。
    static let maxPixelsPerImage = 24_000_000
    static let maxConcurrentJobs = 2

    enum PipelineError: Error, CustomStringConvertible {
        case decodeFailed(String)
        case encodeFailed(String)
        case writeFailed(String)

        var description: String {
            switch self {
            case let .decodeFailed(detail): return "解码失败：\(detail)"
            case let .encodeFailed(detail): return "编码失败：\(detail)"
            case let .writeFailed(detail): return "写入失败：\(detail)"
            }
        }
    }

    // MARK: - 批量入口

    /// 并发处理多个文件（目录由调用方预先展开）。
    /// 支持协作取消：外层 Task 取消后，完成当前分块即提前返回。
    static func process(
        urls: [URL],
        options: ImageJobOptions,
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async -> [ImageJobResult] {
        guard !urls.isEmpty, !Task.isCancelled else { return [] }
        let width = max(1, min(maxConcurrentJobs, ProcessInfo.processInfo.activeProcessorCount))
        var results: [ImageJobResult] = []
        results.reserveCapacity(urls.count)
        var completed = 0

        var index = 0
        while index < urls.count {
            if Task.isCancelled { break }
            let chunkEnd = min(index + width, urls.count)
            let chunk = Array(urls[index ..< chunkEnd])
            let chunkResults: [Int: ImageJobResult] = await withTaskGroup(
                of: (Int, ImageJobResult).self
            ) { group in
                for (offset, url) in chunk.enumerated() {
                    group.addTask {
                        if Task.isCancelled {
                            return (offset, ImageJobResult(source: url, outcome: .failed(detail: "已取消。")))
                        }
                        return (offset, process(url: url, options: options))
                    }
                }
                var collected: [Int: ImageJobResult] = [:]
                for await (offset, result) in group {
                    collected[offset] = result
                }
                return collected
            }
            // 保持与输入顺序一致。
            for offset in 0 ..< chunk.count {
                if let result = chunkResults[offset] {
                    results.append(result)
                    completed += 1
                    progress?(completed, urls.count)
                }
            }
            index = chunkEnd
        }
        return results
    }

    // MARK: - 单文件

    static func process(
        url: URL, options: ImageJobOptions,
        beforeCommit: () throws -> Void = {},
        removeSource: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) -> ImageJobResult {
        do {
            let outcome = try processOrThrow(url: url, options: options, beforeCommit: beforeCommit, removeSource: removeSource)
            return ImageJobResult(source: url, outcome: outcome)
        } catch is CancellationError {
            return ImageJobResult(source: url, outcome: .failed(detail: "已取消。"))
        } catch let error as PipelineError {
            return ImageJobResult(source: url, outcome: .failed(detail: error.description))
        } catch {
            return ImageJobResult(source: url, outcome: .failed(detail: error.localizedDescription))
        }
    }

    private static func processOrThrow(
        url: URL, options: ImageJobOptions,
        beforeCommit: () throws -> Void, removeSource: (URL) throws -> Void
    ) throws -> ImageOutcome {
        try Task.checkCancellation()
        guard let inputFormat = ImageFormat.detect(url: url) else {
            return .unsupported(detail: "无法识别的图像格式。")
        }
        let outputFormat = options.outputFormat ?? inputFormat
        if let reason = ImageCapabilities.unavailableReason(for: outputFormat) {
            return .unsupported(detail: reason)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PipelineError.decodeFailed("CGImageSource 创建失败。")
        }

        // ── 输入安全检查 ─────────────────────────────────────
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else {
            throw PipelineError.decodeFailed("文件不包含可解码的图像帧。")
        }
        guard frameCount == 1 else {
            return .unsupported(detail: "动图（\(frameCount) 帧）暂不支持压缩/转换，已跳过；换 Hash 不受影响。")
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw PipelineError.decodeFailed("无法读取图像尺寸。")
        }
        let pixelCount = pixelWidth * pixelHeight
        guard pixelCount <= maxPixelsPerImage else {
            return .unsupported(
                detail: "图像 \(pixelWidth)×\(pixelHeight)（\(pixelCount / 1_000_000)MP）超过单图 \(maxPixelsPerImage / 1_000_000)MP 上限，已跳过。"
            )
        }

        // ── 解码（方向烘焙 + 可选缩放）──────────────────────
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let needsResize = Self.needsResize(width: pixelWidth, height: pixelHeight, maxDimension: options.maxDimension)
        let image = try decodeImage(
            source: source,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            needsResize: needsResize,
            maxDimension: options.maxDimension,
            bakeOrientation: orientation != 1
        )

        // HDR/位深/辅助图检查（解码后拿得到位深与色彩空间）。
        if let reason = fidelityRiskReason(image: image, source: source) {
            return .unsupported(detail: reason)
        }

        try Task.checkCancellation()
        let originalMetadata = options.stripMetadata
            ? nil
            : CGImageSourceCopyMetadataAtIndex(source, 0, nil)

        // ── 编码 ─────────────────────────────────────────────
        let encoded = try encode(
            image: image,
            outputFormat: outputFormat,
            inputFormat: inputFormat,
            options: options,
            properties: properties,
            metadata: originalMetadata
        )

        let originalSize = fileSize(url) ?? encoded.count
        let didConvert = outputFormat != inputFormat
        let isPureCompression = options.outputFormat == nil && !needsResize && !options.stripMetadata
        if isPureCompression && encoded.count >= originalSize {
            return .noBenefit(originalBytes: originalSize, candidateBytes: encoded.count, detail: "压缩结果不小于原文件。")
        }
        try beforeCommit()
        try Task.checkCancellation()

        // ── 落地 ─────────────────────────────────────────────
        switch options.naming {
        case .overwrite where didConvert:
            // 转换 + 覆盖：写新扩展名文件，成功后删除源文件（先写后删）。
            let target = try AtomicFileReplacer.publishSibling(
                original: url, data: encoded, suffix: "", fileExtension: outputFormat.preferredFilenameExtension
            )
            // Publication begins the commit: finish source cleanup even if cancellation arrives now.
            do {
                try removeSource(url)
            } catch {
                return .sourceRetained(
                    target: target, originalBytes: originalSize, resultBytes: encoded.count,
                    format: outputFormat, detail: "产物已保存，源文件未删除：\(error.localizedDescription)"
                )
            }
            return .converted(
                source: url,
                target: target,
                originalBytes: originalSize,
                resultBytes: encoded.count,
                format: outputFormat
            )
        case .overwrite:
            try AtomicFileReplacer.replace(original: url, data: encoded, tempExtension: "toolbox-image")
            return .replaced(
                originalBytes: originalSize,
                resultBytes: encoded.count,
                format: outputFormat
            )
        case let .suffix(suffix):
            let target = try AtomicFileReplacer.publishSibling(
                original: url, data: encoded, suffix: suffix, fileExtension: outputFormat.preferredFilenameExtension
            )
            return .savedAs(
                target,
                originalBytes: originalSize,
                resultBytes: encoded.count,
                format: outputFormat
            )
        }
    }

    // MARK: - 解码

    /// 解码帧 0：按需缩放（顺带烘焙方向），或在非缩放路径对带方向的图
    /// 用 thumbnail 通道烘焙方向，保证像素正立、不再依赖 orientation 标签。
    private static func decodeImage(
        source: CGImageSource,
        pixelWidth: Int,
        pixelHeight: Int,
        needsResize: Bool,
        maxDimension: Int?,
        bakeOrientation: Bool
    ) throws -> CGImage {
        if needsResize || bakeOrientation {
            let bound = needsResize
                ? maxDimension!
                : max(pixelWidth, pixelHeight) // 不缩放，仅借 thumbnail 通道烘焙方向
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: bound,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) {
                return decoded
            }
            throw PipelineError.decodeFailed("方向变换或缩放失败，已保留原件。")
        }
        guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PipelineError.decodeFailed("帧 0 解码失败。")
        }
        return decoded
    }

    /// 保真风险判定：>8bit、非 sRGB 色彩空间或带增益图辅助数据时，
    /// 重编码必然降级（HDR→SDR、10bit→8bit），拒绝处理。
    private static func fidelityRiskReason(image: CGImage, source: CGImageSource) -> String? {
        if image.bitsPerComponent > 8 {
            return "位深 \(image.bitsPerComponent) bit 的图像暂不支持重编码（避免降级为 8 bit），已跳过。"
        }
        if let colorSpace = image.colorSpace, !isStandardSRGB(colorSpace) {
            let name = (colorSpace.name as String?) ?? "宽色域"
            return "色彩空间 \(name) 暂不支持重编码（避免色域降级），已跳过。"
        }
        // 增益图 / HDR 辅助数据（ISO gain map、Apple HDR）。
        // kCGImageAuxiliaryDataTypeISOGainMap 常量需 macOS 15+，
        // 这里直接用其底层字符串值以兼容 macOS 14。
        let auxiliaryTypes: [CFString] = [
            "public.auxiliary-image.isp-gainmap" as CFString,
            "com.apple.pegasus-metadata" as CFString, // Apple HDR 辅助元数据
        ]
        for type in auxiliaryTypes {
            if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) != nil {
                return "图像包含 HDR 增益图/辅助数据，暂不支持重编码（避免退化为 SDR），已跳过。"
            }
        }
        return nil
    }

    /// 仅接受 sRGB / 设备 RGB；Display P3、Rec.2020、HLG/PQ 等一律拒绝。
    private static func isStandardSRGB(_ colorSpace: CGColorSpace) -> Bool {
        if colorSpace === CGColorSpace.sRGB || colorSpace === CGColorSpace.genericRGBLinear {
            return true
        }
        guard let name = colorSpace.name as String? else {
            return false // 无法判定色彩空间时保守拒绝
        }
        let allowed: Set<String> = [
            "kCGColorSpaceSRGB", "kCGColorSpaceGenericRGB", "kCGColorSpaceDeviceRGB",
        ]
        return allowed.contains(name)
    }

    // MARK: - 编码

    private static func encode(
        image: CGImage,
        outputFormat: ImageFormat,
        inputFormat: ImageFormat,
        options: ImageJobOptions,
        properties: [CFString: Any],
        metadata: CGImageMetadata?
    ) throws -> Data {
        let normalizedMetadata = options.stripMetadata ? nil : try ImageMetadata.normalized(metadata, image: image)
        if outputFormat == .webp {
            let pixels = inputFormat.isLosslessContainer
                ? try WebPEncoder.encodeLossless(image)
                : try WebPEncoder.encodeLossy(image, quality: ImageQualityTable.webpQuality(level: options.level))
            guard let normalizedMetadata else { return pixels }
            let chunks = try ImageMetadata.webPChunks(metadata: normalizedMetadata, properties: properties, image: image)
            return try WebPEncoder.attachMetadata(chunks, to: pixels)
        }

        guard let typeIdentifier = outputFormat.imageIOTypeIdentifier else {
            throw PipelineError.encodeFailed("格式不支持（\(outputFormat.rawValue)）。")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            typeIdentifier as CFString,
            1,
            nil
        ) else {
            throw PipelineError.encodeFailed("CGImageDestination 创建失败（\(outputFormat.rawValue)）。")
        }

        var destinationProperties: [CFString: Any] = [:]
        if outputFormat.isLossy {
            destinationProperties[kCGImageDestinationLossyCompressionQuality] =
                ImageQualityTable.compressionQuality(level: options.level)
        }
        if outputFormat == .tiff {
            // TIFF 用 ZIP/deflate 无损重压缩。
            destinationProperties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: ImageQualityTable.tiffCompressionScheme]
        }

        destinationProperties[kCGImageDestinationEmbedThumbnail] = false
        if let normalizedMetadata {
            destinationProperties[kCGImagePropertyDPIWidth] = properties[kCGImagePropertyDPIWidth]
            destinationProperties[kCGImagePropertyDPIHeight] = properties[kCGImagePropertyDPIHeight]
            CGImageDestinationAddImageAndMetadata(destination, image, normalizedMetadata, destinationProperties as CFDictionary)
        } else {
            // A device RGB image has no embedded profile. Pixel values already use
            // the accepted RGB color space; metadata stripping must not emit ICC.
            guard let untagged = image.copy(colorSpace: CGColorSpaceCreateDeviceRGB()) else {
                throw PipelineError.encodeFailed("无法剥离颜色配置。")
            }
            CGImageDestinationAddImage(destination, untagged, destinationProperties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw PipelineError.encodeFailed("编码未能完成（\(outputFormat.rawValue)）。")
        }
        return output as Data
    }

    // MARK: - 工具

    private static func needsResize(width: Int, height: Int, maxDimension: Int?) -> Bool {
        guard let maxDimension, maxDimension > 0 else { return false }
        return max(width, height) > maxDimension
    }

    private static func fileSize(_ url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int
    }
}
