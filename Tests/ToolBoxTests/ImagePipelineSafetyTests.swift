import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import ToolBoxCore

/// 审计修复的安全语义回归测试：
/// 方向烘焙、动图拒绝、HDR/位深拒绝、像素预算、转换命名、属性保留、去重。
final class ImagePipelineSafetyTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    @discardableResult
    private func track(_ url: URL) -> URL {
        temporaryURLs.append(url)
        return url
    }

    // MARK: - Fixture 构造

    private func makeCGImage(width: Int, height: Int, bitsPerComponent: Int = 8) -> CGImage? {
        if bitsPerComponent == 8 {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let offset = (y * width + x) * 4
                    pixels[offset] = UInt8((x * 255) / max(1, width - 1))
                    pixels[offset + 1] = UInt8((y * 255) / max(1, height - 1))
                    pixels[offset + 2] = 128
                    pixels[offset + 3] = 255
                }
            }
            return pixels.withUnsafeBytes { pointer in
                guard let base = pointer.baseAddress else { return nil }
                return CGContext(
                    data: UnsafeMutableRawPointer(mutating: base),
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: UInt32(CGImageAlphaInfo.premultipliedLast.rawValue)
                        | UInt32(CGImageByteOrderInfo.order32Big.rawValue)
                )?.makeImage()
            }
        }
        // 高位深路径（用于位深拒绝测试）。
        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let offset = (y * width + x) * 4 // 每像素 4 个 UInt16 分量
                pixels[offset] = UInt16((x * 0xFFFF) / max(1, width - 1))
                pixels[offset + 1] = UInt16((y * 0xFFFF) / max(1, height - 1))
                pixels[offset + 2] = 0x8000
                pixels[offset + 3] = 0xFFFF
            }
        }
        let bytesPerComponent = bitsPerComponent / 8
        let bytesPerRow = width * 4 * bytesPerComponent
        return pixels.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return nil }
            return CGContext(
                data: UnsafeMutableRawPointer(mutating: base),
                width: width,
                height: height,
                bitsPerComponent: bitsPerComponent,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: UInt32(CGImageAlphaInfo.premultipliedLast.rawValue)
                    | UInt32(CGImageByteOrderInfo.order16Big.rawValue)
            )?.makeImage()
        }
    }

    /// 带 EXIF 方向标签的 JPEG（orientation=6：需顺时针旋转 90° 才正立）。
    private func makeOrientedJPEG(width: Int = 200, height: Int = 400) throws -> URL {
        guard let image = makeCGImage(width: width, height: height) else {
            throw XCTSkip("无法生成测试图像")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolbox-oriented-\(UUID().uuidString).jpg")
        track(url)
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImagePropertyOrientation: 6] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// 两帧 GIF（动图）。
    private func makeAnimatedGIF() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolbox-animated-\(UUID().uuidString).gif")
        track(url)
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, 2, nil
        )!
        let frameProperties: [CFString: Any] = [kCGImagePropertyGIFDelayTime: 0.1]
        for hue in [UInt8(40), UInt8(200)] {
            guard let image = solidImage(width: 24, height: 24, value: hue) else {
                throw XCTSkip("无法生成 GIF 帧")
            }
            CGImageDestinationAddImage(
                destination, image,
                [kCGImagePropertyGIFDictionary: frameProperties] as CFDictionary
            )
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func solidImage(width: Int, height: Int, value: UInt8) -> CGImage? {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        for offset in stride(from: 0, to: buffer.count, by: 4) {
            buffer[offset] = value
            buffer[offset + 1] = value / 2
            buffer[offset + 2] = 255 - value
            buffer[offset + 3] = 255
        }
        return buffer.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return nil }
            return CGContext(
                data: UnsafeMutableRawPointer(mutating: base),
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: UInt32(CGImageAlphaInfo.premultipliedLast.rawValue)
                    | UInt32(CGImageByteOrderInfo.order32Big.rawValue)
            )?.makeImage()
        }
    }

    // MARK: - F3 方向烘焙

    func testOrientationIsBakedWhenStrippingMetadata() throws {
        let url = try makeOrientedJPEG(width: 200, height: 400) // orientation=6：显示为 400×200
        let result = ImagePipeline.process(
            url: url,
            options: ImageJobOptions(level: 4, stripMetadata: true)
        )
        // 像素级断言：处理后像素应已正立（宽 > 高），不再依赖 orientation 标签。
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        XCTAssertGreaterThan(image.width, image.height, "orientation=6 应烘焙为横向像素")
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        XCTAssertNil(
            properties[kCGImagePropertyOrientation],
            "剥离元数据后不应残留 orientation 标签"
        )
        if case .failed = result.outcome {
            XCTFail("处理不应失败：\(result.outcome)")
        }
    }

    // MARK: - F2 动图拒绝

    func testAnimatedGIFIsRejected() throws {
        let url = try makeAnimatedGIF()
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        XCTAssertGreaterThan(CGImageSourceGetCount(source), 1, "测试前提：GIF 应为多帧")

        let result = ImagePipeline.process(url: url, options: ImageJobOptions(level: 4))
        guard case let .unsupported(detail) = result.outcome else {
            return XCTFail("动图应被拒绝，实际：\(result.outcome)")
        }
        XCTAssertTrue(detail.contains("动图"))
        // 原件未被改动。
        XCTAssertEqual(CGImageSourceGetCount(CGImageSourceCreateWithURL(url as CFURL, nil)!), 2)
    }

    // MARK: - F4 位深拒绝

    func testSixteenBitPNGIsRejected() throws {
        guard let image = makeCGImage(width: 64, height: 64, bitsPerComponent: 16) else {
            throw XCTSkip("无法生成 16bit 测试图像")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolbox-16bit-\(UUID().uuidString).png")
        track(url)
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let result = ImagePipeline.process(url: url, options: ImageJobOptions(level: 4))
        guard case let .unsupported(detail) = result.outcome else {
            return XCTFail("16bit 图应被拒绝，实际：\(result.outcome)")
        }
        XCTAssertTrue(detail.contains("位深"))
    }

    // MARK: - F5 像素预算

    func testOversizedImageIsRejected() throws {
        // 5000×5000 = 25MP，刚超过 24MP 预算（PNG 无损，体积可控）。
        guard let image = makeCGImage(width: 5000, height: 5000) else {
            throw XCTSkip("无法生成测试图像")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolbox-huge-\(UUID().uuidString).png")
        track(url)
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let result = ImagePipeline.process(url: url, options: ImageJobOptions(level: 4))
        guard case .unsupported = result.outcome else {
            return XCTFail("超预算图应被拒绝，实际：\(result.outcome)")
        }
    }

    // MARK: - F1 转换 + 覆盖：新扩展名 + 删源

    func testConvertWithOverwriteWritesNewExtensionAndDeletesSource() throws {
        let url = track(try ImageFixtureFactory.makeFixtureFile(format: .png))
        let result = ImagePipeline.process(
            url: url,
            options: ImageJobOptions(outputFormat: .webp, naming: .overwrite)
        )
        guard case let .converted(source, target, original, output, format) = result.outcome else {
            return XCTFail("预期 converted 结果，实际：\(result.outcome)")
        }
        XCTAssertEqual(format, .webp)
        XCTAssertEqual(target.pathExtension, "webp", "产物必须用新格式扩展名")
        XCTAssertGreaterThan(original, 0)
        XCTAssertGreaterThan(output, 0) // 显式转换允许体积增加。
        track(target)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: source.path),
            "先写后删：源文件应已删除"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        // 产物魔数为 WebP。
        let head = try Data(contentsOf: target).prefix(12)
        XCTAssertEqual(String(data: head.suffix(4), encoding: .ascii), "WEBP")
    }

    func testConvertToSameFormatKeepsOverwriteSemantics() throws {
        // 同格式压缩 + 覆盖仍是原地替换（扩展名不变）。
        let url = track(try ImageFixtureFactory.makeFixtureFile(format: .jpeg))
        let result = ImagePipeline.process(url: url, options: ImageJobOptions(level: 5))
        guard case .replaced = result.outcome else {
            return XCTFail("同格式压缩应走 replaced，实际：\(result.outcome)")
        }
        XCTAssertEqual(url.pathExtension, "jpg")
    }

    // MARK: - F7 权限与 xattr 保留

    func testReplacePreservesPermissionsAndXattr() throws {
        let url = track(try ImageFixtureFactory.makeFixtureFile(format: .png))
        try FileManager.default.setAttributes([.posixPermissions: 0o744], ofItemAtPath: url.path)
        let xattrValue = Data("audit-test".utf8)
        let setOK = xattrValue.withUnsafeBytes { pointer in
            setxattr(url.path, "user.toolboxtest", pointer.baseAddress, xattrValue.count, 0, 0) == 0
        }
        XCTAssertTrue(setOK, "测试前提：能写入自定义 xattr")

        let result = ImagePipeline.process(url: url, options: ImageJobOptions(level: 6))
        if case .failed = result.outcome {
            XCTFail("处理不应失败：\(result.outcome)")
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o744, "权限应保持 0744")

        let valueSize = getxattr(url.path, "user.toolboxtest", nil, 0, 0, 0)
        XCTAssertGreaterThan(valueSize, 0, "自定义 xattr 应保留")
        if valueSize > 0 {
            var buffer = [UInt8](repeating: 0, count: valueSize)
            getxattr(url.path, "user.toolboxtest", &buffer, valueSize, 0, 0)
            XCTAssertEqual(Data(buffer), xattrValue)
        }
    }

    // MARK: - F6 去重

    func testCollectorDeduplicatesOverlappingInputs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolbox-dedupe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.jpg")
        try Data("x".utf8).write(to: file)

        // 目录 + 目录内文件同时指定 → 只处理一次。
        let urls = try ImageFileCollector.collect(
            paths: [directory.path, file.path],
            recursive: true
        )
        XCTAssertEqual(urls.count, 1, "重叠输入应去重")
        // 同一路径重复指定 → 只处理一次。
        let repeated = try ImageFileCollector.collect(
            paths: [file.path, file.path],
            recursive: true
        )
        XCTAssertEqual(repeated.count, 1)
    }
}

import UniformTypeIdentifiers
