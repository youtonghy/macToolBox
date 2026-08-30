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

    static func process(url: URL, options: ImageJobOptions) -> ImageJobResult {
        do {
            let outcome = try processOrThrow(url: url, options: options)
            return ImageJobResult(source: url, outcome: outcome)
        } catch let error as PipelineError {
            return ImageJobResult(source: url, outcome: .failed(detail: error.description))
        } catch {
            return ImageJobResult(source: url, outcome: .failed(detail: error.localizedDescription))
        }
    }

    private static func processOrThrow(url: URL, options: ImageJobOptions) throws -> ImageOutcome {
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
        let didResize = needsResize

        // ── 无收益保护 ───────────────────────────────────────
        if encoded.count >= originalSize {
            let detail: String
            switch (didConvert, didResize) {
            case (true, true): detail = "已转换并缩放，但结果不小于原文件。"
            case (true, false): detail = "已转换为 \(outputFormat.rawValue.uppercased())，但结果不小于原文件。"
            case (false, true): detail = "已缩放，但结果不小于原文件。"
            case (false, false): detail = "压缩结果不小于原文件。"
            }
            return .noBenefit(originalBytes: originalSize, candidateBytes: encoded.count, detail: detail)
        }

        // ── 落地 ─────────────────────────────────────────────
        switch options.naming {
        case .overwrite where didConvert:
            // 转换 + 覆盖：写新扩展名文件，成功后删除源文件（先写后删）。
            let target = uniqueSibling(
                of: url,
                suffix: "",
                extension: outputFormat.preferredFilenameExtension
            )
            do {
                try encoded.write(to: target, options: .atomic)
                try? FileManager.default.removeItem(at: url)
            } catch {
                try? FileManager.default.removeItem(at: target)
                throw PipelineError.writeFailed(error.localizedDescription)
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
            let target = uniqueSibling(
                of: url,
                suffix: suffix,
                extension: outputFormat.preferredFilenameExtension
            )
            do {
                try encoded.write(to: target, options: .atomic)
            } catch {
                throw PipelineError.writeFailed(error.localizedDescription)
            }
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
            // thumbnail 通道失败时继续走直解（方向标签仍会保留/丢失由元数据分支决定）。
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
        if outputFormat == .webp {
            // 无损来源（PNG/TIFF）→ 无损 WebP；其余按级别有损编码。
            // 方向已在解码阶段烘焙进像素。
            if inputFormat.isLosslessContainer {
                return try WebPEncoder.encodeLossless(image)
            }
            return try WebPEncoder.encodeLossy(image, quality: ImageQualityTable.webpQuality(level: options.level))
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
            destinationProperties[kCGImagePropertyTIFFCompression] = ImageQualityTable.tiffCompressionScheme
        }

        var usedMetadataWriter = false
        if !options.stripMetadata {
            // 保留 DPI。方向已烘焙进像素，任何情况下不再写 orientation 标签
            // （避免像素与标签双重旋转）。
            if let dpiWidth = properties[kCGImagePropertyDPIWidth] {
                destinationProperties[kCGImagePropertyDPIWidth] = dpiWidth
            }
            if let dpiHeight = properties[kCGImagePropertyDPIHeight] {
                destinationProperties[kCGImagePropertyDPIHeight] = dpiHeight
            }
            // 完整 EXIF/XMP 元数据走 AddImageAndMetadata；ICC 随 CGImage
            // 色彩空间自动嵌入。
            if let metadata,
               (try? CGImageDestinationAddImageAndMetadata(
                   destination,
                   image,
                   metadata,
                   destinationProperties as CFDictionary
               )) != nil
            {
                usedMetadataWriter = true
            }
        }

        if !usedMetadataWriter {
            CGImageDestinationAddImage(destination, image, destinationProperties as CFDictionary)
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

    private static func uniqueSibling(of url: URL, suffix: String, `extension` fileExtension: String) -> URL {
        let directory = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        let preferredExtension = url.pathExtension.isEmpty ? fileExtension : fileExtension
        var candidate = directory.appendingPathComponent("\(baseName)\(suffix).\(preferredExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)\(suffix)-\(counter).\(preferredExtension)")
            counter += 1
        }
        return candidate
    }

    private static func fileSize(_ url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int
    }
}
