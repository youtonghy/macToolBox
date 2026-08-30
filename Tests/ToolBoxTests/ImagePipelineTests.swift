import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import ToolBoxCore

final class ImagePipelineTests: XCTestCase {
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

    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private func isDecodable(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else { return false }
        return true
    }

    // MARK: - 压缩

    func testCompressJPEGProducesSmallerValidFile() throws {
        let url = track(try ImageFixtureFactory.makeFixtureFile(format: .jpeg))
        let originalSize = fileSize(url)
        let result = ImagePipeline.process(url: url, options: ImageJobOptions(level: 5))

        guard case let .replaced(original, output, format) = result.outcome else {
            return XCTFail("预期原地替换成功，实际：\(result.outcome)")
        }
        XCTAssertEqual(format, .jpeg)
        XCTAssertEqual(original, originalSize)
        XCTAssertLessThan(output, originalSize)
        XCTAssertTrue(isDecodable(url))
    }

    func testCompressPNGUsesLosslessRepack() throws {
        let url = track(try ImageFixtureFactory.makeFixtureFile(format: .png))
        let result = ImagePipeline.process(url: url, options: ImageJobOptions(level: 6))
        // PNG 是无损重打包，压缩渐变图的收益可能不足；无论哪种结果都不能失败。
        if case .failed = result.outcome {
            XCTFail("PNG 重打包不应失败：\(result.outcome)")
        }
        XCTAssertTrue(isDecodable(url))
    }

    func testNoBenefitKeepsOriginal() throws {
        // 构造不可压缩文件：先压到最小，再要求更高质量重压。
        let url = track(try ImageFixtureFactory.makeFixtureFile(format: .jpeg))
        _ = ImagePipeline.process(url: url, options: ImageJobOptions(level: 6))
        let afterFirst = (try Data(contentsOf: url))
        _ = ImagePipeline.process(url: url, options: ImageJobOptions(level: 1)) // 高质量 → 结果更大
        let afterSecond = try Data(contentsOf: url)
        // 高质量档若结果更大，文件必须保持不变（无收益保护）。
        // （存在结果更小的可能，此时第二行不等关系不成立是允许的。）
        if afterSecond.count > afterFirst.count {
            XCTFail("无收益保护失败：结果更大却替换了原件")
        }
        XCTAssertTrue(isDecodable(url))
    }

    // MARK: - 转换

    func testConvertPNGToWebPLosslesslyPreservesPixels() throws {
        let url = track(try ImageFixtureFactory.makeFixtureFile(format: .png))
        let result = ImagePipeline.process(
            url: url,
            options: ImageJobOptions(outputFormat: .webp, naming: .suffix("-webp"))
        )
        guard case let .savedAs(target, _, _, format) = result.outcome else {
            return XCTFail("预期另存成功，实际：\(result.outcome)")
        }
        track(target)
        XCTAssertEqual(format, .webp)
        XCTAssertEqual(target.pathExtension, "webp")
        XCTAssertTrue(isDecodable(target))
        // 无损转换：像素签名一致。
        let before = try pixelSignature(url)
        let after = try pixelSignature(target)
        XCTAssertEqual(before, after)
    }

    func testConvertToJPEGFallbackForUnsupportedFormatOnOlderSystems() throws {
        // AVIF 在 macOS 14 上不可编码时必须优雅降级而不是崩溃。
        let url = track(try ImageFixtureFactory.makeFixtureFile(format: .png))
        let result = ImagePipeline.process(
            url: url,
            options: ImageJobOptions(outputFormat: .avif, naming: .suffix("-avif"))
        )
        switch result.outcome {
        case .savedAs, .converted, .noBenefit, .unsupported:
            break // 四种都可接受（取决于系统能力与压缩收益）
        case .replaced:
            XCTFail("suffix 模式不应产生 replaced")
        case .failed:
            XCTFail("能力缺失应报 unsupported 而不是 failed：\(result.outcome)")
        }
    }

    // MARK: - 缩放与命名

    func testMaxDimensionResizesOutput() throws {
        let url = track(try ImageFixtureFactory.makeFixtureFile(format: .png, width: 400, height: 300))
        let result = ImagePipeline.process(
            url: url,
            options: ImageJobOptions(outputFormat: .jpeg, maxDimension: 100, naming: .suffix("-small"))
        )
        guard case let .savedAs(target, _, _, _) = result.outcome else {
            return XCTFail("预期另存成功，实际：\(result.outcome)")
        }
        track(target)
        let source = CGImageSourceCreateWithURL(target as CFURL, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        let width = properties[kCGImagePropertyPixelWidth] as! Int
        let height = properties[kCGImagePropertyPixelHeight] as! Int
        XCTAssertEqual(max(width, height), 100, "长边应精确等于 max-dimension")
    }

    func testSuffixNamingUniquifiesCollisions() throws {
        let url = track(try ImageFixtureFactory.makeFixtureFile(format: .png))
        let options = ImageJobOptions(outputFormat: .webp, naming: .suffix("-min"))
        let first = ImagePipeline.process(url: url, options: options)
        let second = ImagePipeline.process(url: url, options: options)
        guard case let .savedAs(firstTarget, _, _, _) = first.outcome,
              case let .savedAs(secondTarget, _, _, _) = second.outcome
        else {
            return XCTFail("两次另存都应成功：\(first.outcome) / \(second.outcome)")
        }
        track(firstTarget)
        track(secondTarget)
        XCTAssertNotEqual(firstTarget.lastPathComponent, secondTarget.lastPathComponent)
    }

    func testUnsupportedFileReportsUnsupported() throws {
        let url = track(try ImageFixtureFactory.writeTemporary(
            Data("not an image".utf8),
            extension: "txt"
        ))
        let result = ImagePipeline.process(url: url, options: ImageJobOptions())
        guard case .unsupported = result.outcome else {
            return XCTFail("非图像应报 unsupported，实际：\(result.outcome)")
        }
    }

    // MARK: - 批量与并发

    func testBatchProcessPreservesOrder() async throws {
        var urls: [URL] = []
        for _ in 0 ..< 6 {
            urls.append(track(try ImageFixtureFactory.makeFixtureFile(format: .jpeg)))
        }
        var reported: [Int] = []
        let results = await ImagePipeline.process(urls: urls, options: ImageJobOptions()) { completed, total in
            reported.append(completed)
            XCTAssertGreaterThan(total, 0)
        }
        XCTAssertEqual(results.count, urls.count)
        XCTAssertEqual(results.map(\.source), urls, "结果顺序应与输入一致")
        XCTAssertEqual(reported.last, urls.count)
    }

    // MARK: - 工具

    private func pixelSignature(_ url: URL) throws -> Data {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let width = image.width
        let height = image.height
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            let context = CGContext(
                data: base, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: UInt32(CGImageAlphaInfo.premultipliedLast.rawValue)
                    | UInt32(CGImageByteOrderInfo.order32Big.rawValue)
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return data
    }
}
