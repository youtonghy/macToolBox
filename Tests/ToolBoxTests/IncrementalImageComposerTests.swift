import CoreGraphics
import XCTest
@testable import ToolBox

final class IncrementalImageComposerTests: XCTestCase {
    func testAppendsStripsAndReadsBoundedCrossStripTile() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ScrollCaptureStripStore(
            initialImage: makeRows(width: 4, colors: [(255, 0, 0), (0, 255, 0)]),
            rootDirectory: root
        )
        try store.append(makeRows(width: 4, colors: [(0, 0, 255), (255, 255, 0)]))
        let source = try store.makeImageSource()

        XCTAssertEqual(source.pixelSize, CGSize(width: 4, height: 4))
        let tile = try source.copyPixels(in: CGRect(x: 1, y: 1, width: 2, height: 2))
        XCTAssertEqual(try pixel(in: tile, x: 0, y: 0), RGB(0, 255, 0))
        XCTAssertEqual(try pixel(in: tile, x: 0, y: 1), RGB(0, 0, 255))
    }

    func testFailedAppendDoesNotPublishLogicalHeight() throws {
        let root = temporaryRoot()
        let store = try ScrollCaptureStripStore(
            initialImage: makeRows(width: 2, colors: [(255, 0, 0)]),
            rootDirectory: root
        )
        try FileManager.default.removeItem(at: store.sessionDirectory)

        XCTAssertThrowsError(try store.append(makeRows(width: 2, colors: [(0, 255, 0)])))
        XCTAssertEqual(store.logicalHeight, 1)
    }

    func testRejectsWidthChangeAndOutOfBoundsTile() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ScrollCaptureStripStore(
            initialImage: makeRows(width: 2, colors: [(255, 0, 0)]),
            rootDirectory: root
        )
        XCTAssertThrowsError(try store.append(makeRows(width: 3, colors: [(0, 255, 0)]))) {
            XCTAssertEqual($0 as? ScrollCaptureError, .invalidStrip)
        }
        let source = try store.makeImageSource()
        XCTAssertThrowsError(try source.copyPixels(in: CGRect(x: 0, y: 1, width: 1, height: 1))) {
            XCTAssertEqual($0 as? AnnotationError, .invalidGeometry)
        }
    }

    func testSixtyThousandPixelSourceReadsOnlyRequestedRows() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ScrollCaptureStripStore(
            initialImage: makeSolidImage(width: 1, height: 60_000),
            rootDirectory: root
        )
        let source = try store.makeImageSource()

        let tile = try source.copyPixels(in: CGRect(x: 0, y: 59_990, width: 1, height: 10))

        XCTAssertEqual(tile.width, 1)
        XCTAssertEqual(tile.height, 10)
        XCTAssertEqual(source.lastReadByteCount, 40)
    }

    private func makeRows(width: Int, colors: [(UInt8, UInt8, UInt8)]) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: colors.count,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        for (index, color) in colors.enumerated() {
            context.setFillColor(
                red: CGFloat(color.0) / 255,
                green: CGFloat(color.1) / 255,
                blue: CGFloat(color.2) / 255,
                alpha: 1
            )
            context.fill(CGRect(x: 0, y: index, width: width, height: 1))
        }
        return context.makeImage()!
    }

    private func makeSolidImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private func pixel(in image: CGImage, x: Int, y: Int) throws -> RGB {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            throw TestError.image
        }
        let offset = y * image.bytesPerRow + x * 4
        return RGB(bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("scroll-store-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private struct RGB: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8

        init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    private enum TestError: Error { case image }
}
