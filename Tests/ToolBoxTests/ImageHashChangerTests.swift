import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XCTest

@testable import ToolBoxCore

final class ImageHashChangerTests: XCTestCase {
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

    /// 对一个 fixture 断言换 Hash 的全部不变量：
    /// ① 哈希变化 ②可解码 ③像素逐位一致 ④重复执行仍变化（幂等剥离）。
    /// payload 默认 600 字节，超过 GIF 单子块 255 字节上限以覆盖分块路径。
    private func assertRoundTrip(format: ImageFormat, payloadSize: Int = 600) throws {
        guard let image = ImageFixtureFactory.makeImage(width: 96, height: 64) else {
            throw XCTSkip("无法生成测试图像")
        }
        let original: Data
        switch format {
        case .webp:
            original = try ImageFixtureFactory.encodeWebP(image)
        default:
            guard let data = ImageFixtureFactory.encode(image, format: format) else {
                throw XCTSkip("当前系统不支持编码 \(format.rawValue)")
            }
            original = data
        }
        guard original.count > 12 else {
            throw XCTSkip("fixture 异常过小")
        }

        let payload = Data(repeating: 0xAB, count: payloadSize) // 超过 255 字节覆盖 GIF 子块分块路径
        let mutated = try ImageHashChanger.mutate(data: original, format: format)

        // ① 哈希变化。
        XCTAssertNotEqual(
            SHA256.hash(data: original),
            SHA256.hash(data: mutated),
            "\(format.rawValue)：换 Hash 后摘要未变化"
        )
        // ② 产物可解码。
        guard let source = CGImageSourceCreateWithData(mutated as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else {
            return XCTFail("\(format.rawValue)：产物无法解码")
        }
        // ③ 像素逐位一致。
        let originalSignature = renderSignature(original)
        let mutatedSignature = renderSignature(mutated)
        XCTAssertEqual(originalSignature, mutatedSignature, "\(format.rawValue)：像素被修改")

        // ④ 重复换 Hash：剥离旧注入 + 新随机载荷 → 与第一次产物不同。
        let mutatedAgain = try ImageHashChanger.mutate(data: mutated, format: format)
        XCTAssertNotEqual(mutated, mutatedAgain, "\(format.rawValue)：重复换 Hash 未产生新内容")
        // 剥离旧注入后体积不应持续增长（允许 ±注入块本身大小）。
        XCTAssertLessThan(
            mutatedAgain.count - original.count,
            payloadSize + ImageHashChanger.injectionMarker.count + 16,
            "\(format.rawValue)：重复换 Hash 后文件异常增长"
        )
    }

    func testJPEG() throws { try assertRoundTrip(format: .jpeg) }
    func testPNG() throws { try assertRoundTrip(format: .png) }
    func testWebP() throws { try assertRoundTrip(format: .webp) }
    func testGIF() throws { try assertRoundTrip(format: .gif) }
    func testTIFF() throws { try assertRoundTrip(format: .tiff) }

    func testHEICAndAVIFWhenSupported() throws {
        // HEIC 全系统可编码；AVIF 视系统而定（macOS 15+）。
        for format in [ImageFormat.heic, .avif] {
            guard ImageCapabilities.canImageIOEncode(format) else { continue }
            try assertRoundTrip(format: format)
        }
    }

    // MARK: - 文件级

    func testRehashURLChangesHashesAndKeepsPixels() throws {
        let url = track(try ImageFixtureFactory.makeFixtureFile(format: .png))
        let before = try Data(contentsOf: url)
        let result = ImageHashChanger.rehash(url: url)

        guard case let .replaced(beforeHashes, afterHashes, _) = result.outcome else {
            return XCTFail("预期换 Hash 成功，实际：\(result.outcome)")
        }
        XCTAssertEqual(beforeHashes.md5, md5Hex(before))
        XCTAssertNotEqual(beforeHashes.md5, afterHashes.md5)
        XCTAssertNotEqual(beforeHashes.sha256, afterHashes.sha256)

        let after = try Data(contentsOf: url)
        XCTAssertEqual(afterHashes.sha256, sha256Hex(after))
        XCTAssertEqual(renderSignature(before), renderSignature(after), "像素必须逐位一致")
    }

    func testRehashRejectsNonImage() throws {
        let url = track(try ImageFixtureFactory.writeTemporary(
            Data("plain text".utf8), extension: "txt"
        ))
        let result = ImageHashChanger.rehash(url: url)
        guard case .unsupported = result.outcome else {
            return XCTFail("非图像应报 unsupported，实际：\(result.outcome)")
        }
    }

    // MARK: - 异常结构

    func testMalformedInputsThrow() {
        XCTAssertThrowsError(try JPEGHashMutator.mutate(
            Data("no-soi-marker".utf8),
            payload: Data("x".utf8)
        ))
        XCTAssertThrowsError(try PNGHashMutator.mutate(
            Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x00, 0x00, 0xFF]),
            payload: Data("x".utf8)
        ))
        XCTAssertThrowsError(try WebPHashMutator.mutate(
            Data("RIFFxxxxJUNKnot-webp".utf8),
            payload: Data("x".utf8)
        ))
        XCTAssertThrowsError(try TIFFHashMutator.mutate(
            Data("not-tiff".utf8),
            payload: Data("x".utf8)
        ))
    }

    func testCRC32KnownVectors() {
        // 标准 CRC-32/ISO-HDLC 测试向量。
        XCTAssertEqual(CRC32.checksum(Data()), 0x00000000)
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF43926)
        XCTAssertEqual(
            CRC32.checksum(Data("The quick brown fox jumps over the lazy dog".utf8)),
            0x414FA339
        )
    }

    // MARK: - 工具

    private func renderSignature(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let width = image.width
        let height = image.height
        var buffer = Data(count: width * height * 4)
        buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let context = CGContext(
                data: base, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: UInt32(CGImageAlphaInfo.premultipliedLast.rawValue)
                    | UInt32(CGImageByteOrderInfo.order32Big.rawValue)
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buffer
    }

    private func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
