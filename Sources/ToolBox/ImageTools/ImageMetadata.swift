import CoreGraphics
import Foundation
import ImageIO

/// One normalized metadata representation for ImageIO and WebP outputs.
enum ImageMetadata {
    static func normalized(_ metadata: CGImageMetadata?, image: CGImage) throws -> CGImageMetadata {
        let result: CGMutableImageMetadata
        if let metadata {
            guard let copy = CGImageMetadataCreateMutableCopy(metadata) else {
                throw ImagePipeline.PipelineError.encodeFailed("无法复制元数据。")
            }
            result = copy
        } else {
            result = CGImageMetadataCreateMutable()
        }
        let values: [(CFString, CFString, Int)] = [
            (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 1),
            (kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelXDimension, image.width),
            (kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelYDimension, image.height),
        ]
        for (dictionary, key, value) in values {
            guard CGImageMetadataSetValueMatchingImageProperty(result, dictionary, key, value as CFNumber) else {
                throw ImagePipeline.PipelineError.encodeFailed("无法更新元数据方向或尺寸。")
            }
        }
        for (path, value) in [("tiff:ImageWidth", image.width), ("tiff:ImageLength", image.height)] {
            guard CGImageMetadataSetValueWithPath(result, nil, path as CFString, value as CFNumber) else {
                throw ImagePipeline.PipelineError.encodeFailed("无法更新元数据尺寸。")
            }
        }
        return result
    }

    /// Let ImageIO serialize EXIF/GPS/DPI, using a tiny carrier image rather than
    /// hand-writing TIFF offsets. The carrier's pixels are never included in WebP.
    static func webPChunks(
        metadata: CGImageMetadata, properties: [CFString: Any], image: CGImage
    ) throws -> [(String, Data)] {
        guard let xmp = CGImageMetadataCreateXMPData(metadata, nil) as Data?,
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let carrier = context.makeImage()
        else { throw ImagePipeline.PipelineError.encodeFailed("无法序列化元数据。") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            throw ImagePipeline.PipelineError.encodeFailed("无法创建 EXIF 编码器。")
        }
        var options: [CFString: Any] = [kCGImageDestinationEmbedThumbnail: false]
        options[kCGImagePropertyDPIWidth] = properties[kCGImagePropertyDPIWidth]
        options[kCGImagePropertyDPIHeight] = properties[kCGImagePropertyDPIHeight]
        CGImageDestinationAddImageAndMetadata(destination, carrier, metadata, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImagePipeline.PipelineError.encodeFailed("无法保存 EXIF 元数据。")
        }
        // JPEG APP1 Exif payload is a TIFF stream prefixed by Exif\0\0.
        let bytes = output as Data
        var cursor = 2
        var exif: Data?
        while cursor + 4 <= bytes.count, bytes[cursor] == 0xFF {
            let marker = bytes[cursor + 1]
            if marker == 0xDA || marker == 0xD9 { break }
            let size = Int(bytes[cursor + 2]) << 8 | Int(bytes[cursor + 3])
            guard size >= 2, size <= bytes.count - cursor - 2 else { break }
            let payload = bytes[(cursor + 4)..<(cursor + 2 + size)]
            if marker == 0xE1, payload.starts(with: Data([69, 120, 105, 102, 0, 0])) {
                exif = Data(payload.dropFirst(6))
                break
            }
            cursor += 2 + size
        }
        guard var exif else { throw ImagePipeline.PipelineError.encodeFailed("无法提取 EXIF 元数据。") }
        try updateEXIFDimensions(&exif, width: image.width, height: image.height)
        var chunks = [("EXIF", exif), ("XMP ", xmp)]
        if let colorSpace = image.colorSpace,
           let profile = colorSpace.copyICCData() as Data? {
            chunks.append(("ICCP", profile))
        }
        return chunks
    }

    /// ImageIO writes the carrier's 1×1 dimensions into EXIF. Update only the
    /// inline numeric fields in this freshly generated TIFF stream (no relocation).
    private static func updateEXIFDimensions(_ data: inout Data, width: Int, height: Int) throws {
        let little = data.prefix(2) == Data([0x49, 0x49])
        func read(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 0, offset <= data.count - count else {
                throw ImagePipeline.PipelineError.encodeFailed("EXIF 偏移无效。")
            }
            return (0..<count).reduce(0) { value, index in
                value | Int(data[offset + index]) << ((little ? index : count - index - 1) * 8)
            }
        }
        func entries(_ offset: Int) throws -> [Int] {
            let count = try read(offset, 2)
            guard count <= (data.count - offset - 2) / 12 else {
                throw ImagePipeline.PipelineError.encodeFailed("EXIF 目录无效。")
            }
            return (0..<count).map { offset + 2 + $0 * 12 }
        }
        let root = try read(4, 4)
        var replacements: [(Int, Int)] = []
        var exifOffset: Int?
        for entry in try entries(root) {
            switch try read(entry, 2) {
            case 0x0100: replacements.append((entry, width))
            case 0x0101: replacements.append((entry, height))
            case 0x8769: exifOffset = try read(entry + 8, 4)
            default: break
            }
        }
        guard let exifOffset else { throw ImagePipeline.PipelineError.encodeFailed("缺少 EXIF 目录。") }
        var found = 0
        for entry in try entries(exifOffset) {
            switch try read(entry, 2) {
            case 0xA002: replacements.append((entry, width)); found += 1
            case 0xA003: replacements.append((entry, height)); found += 1
            default: break
            }
        }
        guard found == 2 else { throw ImagePipeline.PipelineError.encodeFailed("缺少 EXIF 尺寸。") }
        for (entry, value) in replacements {
            for (offset, count, number) in [(entry + 2, 2, 4), (entry + 4, 4, 1), (entry + 8, 4, value)] {
                for index in 0..<count {
                    data[offset + index] = UInt8(truncatingIfNeeded: number >> ((little ? index : count - index - 1) * 8))
                }
            }
        }
    }

}
