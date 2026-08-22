import CoreGraphics
import XCTest
@testable import ToolBoxCore

final class IncrementalImageComposerTests: XCTestCase {
    func testScrollImageSourcePreservesRasterizedPixelOrientation() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = makeRows(
            width: 4,
            colors: [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)]
        )
        let store = try ScrollCaptureStripStore(initialImage: original, rootDirectory: root)
        let source = try store.makeImageSource()

        let roundTrip = try source.copyPixels(in: CGRect(x: 0, y: 0, width: 4, height: 4))
        let originalPixels = try PaddleOCRImagePreprocessor.rasterizedImage(image: original)
        let roundTripPixels = try PaddleOCRImagePreprocessor.rasterizedImage(image: roundTrip)

        XCTAssertEqual(roundTripPixels.pixels, originalPixels.pixels)
    }

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
        XCTAssertEqual(try pixel(in: tile, x: 0, y: 0), RGB(0, 0, 255))
        XCTAssertEqual(try pixel(in: tile, x: 0, y: 1), RGB(0, 255, 0))
        XCTAssertEqual(source.lastReadOperationCount, 2)
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
        XCTAssertEqual(source.lastReadOperationCount, 1)
    }

    func testReopensSessionUsingPersistedCustomBudget() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ScrollCaptureStripStore(
            initialImage: makeSolidImage(width: 1, height: 60_001),
            rootDirectory: root,
            budget: ScrollCaptureResourceBudget(maximumHeight: 70_000, maximumRGBABytes: 300_000)
        )

        let source = try ScrollCaptureImageSource(sessionDirectory: store.sessionDirectory)

        XCTAssertEqual(source.pixelSize.height, 60_001)
    }

    func testRejectsPathTraversalSymlinkAndForgedStripSize() throws {
        for mutation in MetadataMutation.allCases {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try ScrollCaptureStripStore(
                initialImage: makeSolidImage(width: 2, height: 2),
                rootDirectory: root
            )
            let metadataURL = store.sessionDirectory.appendingPathComponent("metadata.json")
            var metadata = try JSONDecoder().decode(
                ScrollCaptureStripMetadata.self,
                from: Data(contentsOf: metadataURL)
            )
            let original = metadata.strips[0]
            switch mutation {
            case .pathTraversal:
                metadata.strips[0] = ScrollCaptureStripRecord(
                    fileName: "../outside.rgba",
                    startRow: original.startRow,
                    height: original.height,
                    byteCount: original.byteCount
                )
            case .forgedSize:
                metadata.strips[0] = ScrollCaptureStripRecord(
                    fileName: original.fileName,
                    startRow: original.startRow,
                    height: original.height,
                    byteCount: original.byteCount + 4
                )
            case .symlink:
                let stripURL = store.sessionDirectory.appendingPathComponent(original.fileName)
                let target = store.sessionDirectory.appendingPathComponent("target.rgba")
                try FileManager.default.moveItem(at: stripURL, to: target)
                try FileManager.default.createSymbolicLink(at: stripURL, withDestinationURL: target)
            }
            try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)

            XCTAssertThrowsError(try ScrollCaptureImageSource(sessionDirectory: store.sessionDirectory)) {
                XCTAssertEqual($0 as? ScrollCaptureError, .corruptMetadata, "mutation: \(mutation)")
            }
        }
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
        let rasterized = try PaddleOCRImagePreprocessor.rasterizedImage(image: image)
        let offset = (y * rasterized.width + x) * 4
        return RGB(
            rasterized.pixels[offset],
            rasterized.pixels[offset + 1],
            rasterized.pixels[offset + 2]
        )
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

    private enum MetadataMutation: CaseIterable {
        case pathTraversal
        case forgedSize
        case symlink
    }
}
