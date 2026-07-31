import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ScreenshotPNGExporter {
    static let defaultMaximumExportBytes = 512 * 1_024 * 1_024

    let renderer: AnnotationRenderer
    let maximumExportBytes: Int

    init(
        renderer: AnnotationRenderer = AnnotationRenderer(),
        maximumExportBytes: Int = defaultMaximumExportBytes
    ) {
        self.renderer = renderer
        self.maximumExportBytes = max(4, maximumExportBytes)
    }

    func export(document: ScreenshotDocument, to url: URL) throws {
        let dimensions = try ScreenshotPixelDimensions(size: document.baseImage.pixelSize)
        guard dimensions.byteCount <= maximumExportBytes else {
            throw AnnotationRenderError.exportTooLarge
        }
        let width = dimensions.width
        let height = dimensions.height
        let bytesPerRow = dimensions.bytesPerRow
        let byteCount = dimensions.byteCount

        let rawURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolbox-screenshot-\(UUID().uuidString).rgba")
        let descriptor = Darwin.open(rawURL.path, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AnnotationRenderError.fileMappingFailed }
        defer {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: rawURL)
        }
        guard ftruncate(descriptor, off_t(byteCount)) == 0 else {
            throw AnnotationRenderError.fileMappingFailed
        }
        let mapped = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0)
        guard mapped != MAP_FAILED, let mapped else {
            throw AnnotationRenderError.fileMappingFailed
        }
        defer { munmap(mapped, byteCount) }

        let bandHeight = try renderer.bandHeight(forWidth: width)
        var y = 0
        while y < height {
            let currentHeight = min(bandHeight, height - y)
            let rect = CGRect(x: 0, y: y, width: width, height: currentHeight)
            let band = try renderer.renderBand(document: document, pixelRect: rect)
            guard let data = band.dataProvider?.data,
                  let source = CFDataGetBytePtr(data),
                  band.bytesPerRow >= bytesPerRow
            else {
                throw AnnotationRenderError.imageCreationFailed
            }
            for row in 0..<currentHeight {
                memcpy(
                    mapped.advanced(by: (y + row) * bytesPerRow),
                    source.advanced(by: row * band.bytesPerRow),
                    bytesPerRow
                )
            }
            y += currentHeight
        }

        guard msync(mapped, byteCount, MS_SYNC) == 0,
              let provider = CGDataProvider(
                  dataInfo: nil,
                  data: mapped,
                  size: byteCount,
                  releaseData: { _, _, _ in }
              ),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  UTType.png.identifier as CFString,
                  1,
                  nil
              )
        else {
            throw AnnotationRenderError.exportFailed
        }

        let properties: [CFString: Any] = [
            kCGImagePropertyPixelWidth: width,
            kCGImagePropertyPixelHeight: height,
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGInterlaceType: 0,
            ],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw AnnotationRenderError.exportFailed
        }
    }
}
