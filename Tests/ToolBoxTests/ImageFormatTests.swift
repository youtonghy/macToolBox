import XCTest

@testable import ToolBoxCore

final class ImageFormatTests: XCTestCase {
    func testDetectsJPEGByMagic() {
        let data = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01])
        XCTAssertEqual(ImageFormat.detect(dataPrefix: data), .jpeg)
    }

    func testDetectsPNGByMagic() {
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
        XCTAssertEqual(ImageFormat.detect(dataPrefix: data), .png)
    }

    func testDetectsGIFByMagic() {
        let data = Data("GIF89a".utf8) + Data(repeating: 0, count: 8)
        XCTAssertEqual(ImageFormat.detect(dataPrefix: data), .gif)
    }

    func testDetectsTIFFBothEndianness() {
        XCTAssertEqual(
            ImageFormat.detect(dataPrefix: Data([0x49, 0x49, 0x2A, 0x00, 0, 0, 0, 0, 0, 0, 0, 0])),
            .tiff
        )
        XCTAssertEqual(
            ImageFormat.detect(dataPrefix: Data([0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 0, 0, 0, 0, 0])),
            .tiff
        )
    }

    func testDetectsWebPByRIFFForm() {
        let data = Data("RIFF".utf8) + Data([0x24, 0x00, 0x00, 0x00]) + Data("WEBPVP8 ".utf8)
        XCTAssertEqual(ImageFormat.detect(dataPrefix: data), .webp)
    }

    func testDetectsAVIFAndHEICByBrand() {
        func container(_ brand: String) -> Data {
            Data([0, 0, 0, 0x14]) + Data("ftyp".utf8) + Data(brand.utf8) + Data(repeating: 0, count: 8)
        }
        XCTAssertEqual(ImageFormat.detect(dataPrefix: container("avif")), .avif)
        XCTAssertEqual(ImageFormat.detect(dataPrefix: container("heic")), .heic)
        XCTAssertEqual(ImageFormat.detect(dataPrefix: container("mif1")), .heic)
    }

    func testRejectsUnknownData() {
        XCTAssertNil(ImageFormat.detect(dataPrefix: Data("hello world!!".utf8)))
        XCTAssertNil(ImageFormat.detect(dataPrefix: Data([0x00])))
    }

    func testQualityTableLevels() {
        XCTAssertEqual(ImageQualityTable.normalizeLevel(0), 1)
        XCTAssertEqual(ImageQualityTable.normalizeLevel(99), 6)
        XCTAssertEqual(ImageQualityTable.normalizeLevel(3), 3)
        // 级别越高（数值大）质量越低 → 文件越小。
        XCTAssertGreaterThan(
            ImageQualityTable.compressionQuality(level: 1),
            ImageQualityTable.compressionQuality(level: 6)
        )
    }
}
