import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ScreenshotPNGExporter {
    let renderer: AnnotationRenderer

    init(renderer: AnnotationRenderer = AnnotationRenderer()) {
        self.renderer = renderer
    }

    func export(document: ScreenshotDocument, to url: URL) throws {
        let width = Int(document.baseImage.pixelSize.width)
        let height = Int(document.baseImage.pixelSize.height)
        guard width > 0,
              height > 0,
              let bytesPerRow = checkedProduct(width, 4),
              let byteCount = checkedProduct(bytesPerRow, height)
        else {
            throw AnnotationRenderError.invalidDimensions
        }

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

    private func checkedProduct(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? nil : result.partialValue
    }
}
