import CoreGraphics
import Foundation

final class ScrollCaptureImageSource: ScreenshotImageSource, @unchecked Sendable {
    let id: UUID
    let pixelSize: CGSize
    private(set) var lastReadByteCount = 0
    private(set) var lastReadOperationCount = 0

    private let sessionDirectory: URL
    private let metadata: ScrollCaptureStripMetadata

    init(sessionDirectory: URL) throws {
        let metadataURL = sessionDirectory.appendingPathComponent("metadata.json")
        do {
            let metadataValues = try metadataURL.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard metadataValues.isSymbolicLink != true,
                  let metadataSize = metadataValues.fileSize,
                  metadataSize <= 1_048_576
            else {
                throw ScrollCaptureError.corruptMetadata
            }
            let data = try Data(contentsOf: metadataURL)
            let decoded = try JSONDecoder().decode(ScrollCaptureStripMetadata.self, from: data)
            try Self.validate(decoded, in: sessionDirectory)
            metadata = decoded
            id = decoded.sessionID
            pixelSize = CGSize(width: decoded.width, height: decoded.height)
            self.sessionDirectory = sessionDirectory
        } catch let error as ScrollCaptureError {
            throw error
        } catch {
            throw ScrollCaptureError.corruptMetadata
        }
    }

    func copyPixels(in rect: CGRect) throws -> CGImage {
        let bounds = CGRect(origin: .zero, size: pixelSize)
        guard rect.isIntegralPixelRect,
              rect.width > 0,
              rect.height > 0,
              bounds.contains(rect)
        else {
            throw AnnotationError.invalidGeometry
        }
        let x = Int(rect.minX)
        let y = Int(rect.minY)
        let width = Int(rect.width)
        let height = Int(rect.height)
        let bytesPerRow = width * 4
        let sourceBytesPerRow = metadata.width * 4
        var output = Data(count: bytesPerRow * height)
        var readOperationCount = 0

        try output.withUnsafeMutableBytes { outputBytes in
            guard let destination = outputBytes.baseAddress else {
                throw ScrollCaptureError.storageFailure
            }
            for strip in metadata.strips {
                let stripRange = strip.startRow..<(strip.startRow + strip.height)
                let requestedRange = y..<(y + height)
                let lower = max(stripRange.lowerBound, requestedRange.lowerBound)
                let upper = min(stripRange.upperBound, requestedRange.upperBound)
                guard lower < upper else { continue }
                let handle = try FileHandle(
                    forReadingFrom: sessionDirectory.appendingPathComponent(strip.fileName)
                )
                defer { try? handle.close() }
                let firstStripRow = lower - strip.startRow
                let intersectingRows = upper - lower
                let sourceOffset = UInt64(firstStripRow * sourceBytesPerRow + x * 4)
                let blockByteCount = (intersectingRows - 1) * sourceBytesPerRow + bytesPerRow
                try handle.seek(toOffset: sourceOffset)
                guard let block = try handle.read(upToCount: blockByteCount),
                      block.count == blockByteCount
                else { throw ScrollCaptureError.corruptMetadata }
                readOperationCount += 1
                block.withUnsafeBytes { sourceBytes in
                    guard let source = sourceBytes.baseAddress else { return }
                    for row in 0..<intersectingRows {
                        destination.advanced(by: (lower - y + row) * bytesPerRow).copyMemory(
                            from: source.advanced(by: row * sourceBytesPerRow),
                            byteCount: bytesPerRow
                        )
                    }
                }
            }
        }
        lastReadByteCount = output.count
        lastReadOperationCount = readOperationCount

        guard let provider = CGDataProvider(data: output as CFData),
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
              )
        else {
            throw ScrollCaptureError.storageFailure
        }
        return image
    }

    private static func validate(
        _ metadata: ScrollCaptureStripMetadata,
        in directory: URL
    ) throws {
        guard metadata.version == 2,
              metadata.width > 0,
              metadata.height > 0,
              metadata.maximumHeight > 0,
              metadata.maximumRGBABytes >= 4,
              !metadata.strips.isEmpty
        else {
            throw ScrollCaptureError.corruptMetadata
        }
        do {
            _ = try ScrollCaptureResourceBudget(
                maximumHeight: metadata.maximumHeight,
                maximumRGBABytes: metadata.maximumRGBABytes
            ).validateAppend(
                width: metadata.width,
                currentHeight: 0,
                additionalRows: metadata.height
            )
        } catch {
            throw ScrollCaptureError.corruptMetadata
        }
        var expectedStart = 0
        for strip in metadata.strips {
            let rowBytes = metadata.width.multipliedReportingOverflow(by: 4)
            let expectedByteResult = rowBytes.partialValue.multipliedReportingOverflow(by: strip.height)
            guard !rowBytes.overflow, !expectedByteResult.overflow else {
                throw ScrollCaptureError.corruptMetadata
            }
            let expectedBytes = expectedByteResult.partialValue
            let url = directory.appendingPathComponent(strip.fileName)
            let values = try? url.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard strip.startRow == expectedStart,
                  strip.height > 0,
                  strip.byteCount == expectedBytes,
                  strip.fileName.hasPrefix("strip-"),
                  strip.fileName.hasSuffix(".rgba"),
                  !strip.fileName.contains(".."),
                  URL(fileURLWithPath: strip.fileName).lastPathComponent == strip.fileName,
                  values?.isRegularFile == true,
                  values?.isSymbolicLink != true,
                  values?.fileSize == expectedBytes
            else {
                throw ScrollCaptureError.corruptMetadata
            }
            expectedStart += strip.height
        }
        guard expectedStart == metadata.height else {
            throw ScrollCaptureError.corruptMetadata
        }
    }
}

private extension CGRect {
    var isIntegralPixelRect: Bool {
        minX.isFinite
            && minY.isFinite
            && width.isFinite
            && height.isFinite
            && minX.rounded(.towardZero) == minX
            && minY.rounded(.towardZero) == minY
            && width.rounded(.towardZero) == width
            && height.rounded(.towardZero) == height
    }
}
