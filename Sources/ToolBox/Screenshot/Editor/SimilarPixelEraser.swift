import CoreGraphics
import Darwin
import Foundation

/// Immutable results shared by preview, export and undo snapshots.
final class ScreenshotPixelPatch: @unchecked Sendable, Equatable {
    let image: CGImage
    let source: ScreenshotImageSource
    let preview: ScreenshotEditorPreview?
    let sensitivity: Double
    let changedPixelCount: Int
    var byteCount: Int { image.width * image.height * 4 }

    init(image: CGImage, source: ScreenshotImageSource? = nil,
         preview: ScreenshotEditorPreview? = nil, sensitivity: Double = 15, changedPixelCount: Int = 0) {
        self.image = image
        self.source = source ?? CGImageScreenshotSource(image: image)
        self.preview = preview
        self.sensitivity = sensitivity
        self.changedPixelCount = changedPixelCount
    }

    static func == (lhs: ScreenshotPixelPatch, rhs: ScreenshotPixelPatch) -> Bool { lhs === rhs }
}

enum SimilarPixelEraseError: Error {
    case imageTooLarge
    case storageUnavailable
    case historyTooLarge
}

/// Each allocation is backed by an unlinked, preallocated file. Closing the final
/// reference releases its disk space, including after cancellation or process exit.
private final class PixelMappedBuffer {
    let pointer: UnsafeMutableRawPointer
    let byteCount: Int

    init(byteCount: Int) throws {
        try Task.checkCancellation()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("toolbox-pixels-\(UUID()).raw")
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw SimilarPixelEraseError.storageUnavailable }
        defer { Darwin.close(fd) }
        Darwin.unlink(url.path)
        // Reserve the blocks before mmap writes, rather than relying on a sparse
        // file that could fault when the volume runs out of space halfway through.
        var allocation = fstore_t(fst_flags: UInt32(F_ALLOCATEALL), fst_posmode: F_PEOFPOSMODE,
                                 fst_offset: 0, fst_length: off_t(byteCount), fst_bytesalloc: 0)
        guard fcntl(fd, F_PREALLOCATE, &allocation) != -1,
              ftruncate(fd, off_t(byteCount)) == 0 else {
            throw SimilarPixelEraseError.storageUnavailable
        }
        let mapped = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard mapped != MAP_FAILED, let mapped else { throw SimilarPixelEraseError.storageUnavailable }
        pointer = mapped
        self.byteCount = byteCount
    }

    deinit { munmap(pointer, byteCount) }
}

/// The mapping is written only by the processor, before publishing this source.
private final class MappedPixelSource: ScreenshotImageSource, @unchecked Sendable {
    let id = UUID()
    let dimensions: ScreenshotPixelDimensions
    private let buffer: PixelMappedBuffer
    var pixelSize: CGSize { CGSize(width: dimensions.width, height: dimensions.height) }

    init(buffer: PixelMappedBuffer, dimensions: ScreenshotPixelDimensions) {
        self.buffer = buffer
        self.dimensions = dimensions
    }

    func fullImage() throws -> CGImage {
        let owner = Unmanaged.passRetained(buffer).toOpaque()
        guard let provider = CGDataProvider(dataInfo: owner, data: buffer.pointer, size: buffer.byteCount,
                                           releaseData: { info, _, _ in
            if let info { Unmanaged<PixelMappedBuffer>.fromOpaque(info).release() }
        }) else {
            Unmanaged<PixelMappedBuffer>.fromOpaque(owner).release()
            throw AnnotationRenderError.imageCreationFailed
        }
        return try makeImage(provider: provider, width: dimensions.width, height: dimensions.height)
    }

    func copyPixels(in rect: CGRect) throws -> CGImage {
        guard rect == rect.integral, rect.width > 0, rect.height > 0,
              CGRect(origin: .zero, size: pixelSize).contains(rect) else { throw AnnotationError.invalidGeometry }
        let width = Int(rect.width), height = Int(rect.height)
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { bytes in
            for row in 0..<height {
                bytes.baseAddress!.advanced(by: row * width * 4).copyMemory(
                    from: buffer.pointer.advanced(by: (Int(rect.minY) + row) * dimensions.bytesPerRow + Int(rect.minX) * 4),
                    byteCount: width * 4)
            }
        }
        guard let provider = CGDataProvider(data: data as CFData) else { throw AnnotationRenderError.imageCreationFailed }
        return try makeImage(provider: provider, width: width, height: height)
    }

    private func makeImage(provider: CGDataProvider, width: Int, height: Int) throws -> CGImage {
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw AnnotationRenderError.imageCreationFailed
        }
        return image
    }
}

struct SimilarPixelEraser: Sendable {
    static let maximumImageBytes = ScreenshotPNGExporter.defaultMaximumExportBytes
    static let maximumHistoryBytes = 2 * 1_024 * 1_024 * 1_024
    let sourceBandBytes: Int

    init(sourceBandBytes: Int = 8 * 1_024 * 1_024) { self.sourceBandBytes = max(4, sourceBandBytes) }

    func process(source: ScreenshotImageSource, sensitivity: Double,
                 progress: @Sendable (Double) -> Void = { _ in }) throws -> ScreenshotPixelPatch {
        try process(source: source, rect: CGRect(origin: .zero, size: source.pixelSize),
                    sensitivity: sensitivity, progress: progress)
    }

    // Kept as a processing primitive for small synthetic fixtures. The UI always uses the full image.
    func process(source: ScreenshotImageSource, rect: CGRect, sensitivity: Double,
                 progress: @Sendable (Double) -> Void = { _ in }) throws -> ScreenshotPixelPatch {
        guard sensitivity.isFinite, (0...100).contains(sensitivity),
              rect == rect.integral, rect.width > 0, rect.height > 0,
              CGRect(origin: .zero, size: source.pixelSize).contains(rect) else { throw AnnotationError.invalidGeometry }
        let source = topLeftScreenshotSource(source)
        let dimensions = try ScreenshotPixelDimensions(size: rect.size)
        guard dimensions.byteCount <= Self.maximumImageBytes else { throw SimilarPixelEraseError.imageTooLarge }
        try Task.checkCancellation()
        // Input, output, visited flags and the largest possible flood-fill queue.
        // A reserve leaves room for the preview and other small temporary files.
        let workingBytes = sensitivity == 0 ? dimensions.byteCount * 2 : dimensions.byteCount * 3 + dimensions.width * dimensions.height
        let requiredBytes = workingBytes + 64 * 1_024 * 1_024
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: FileManager.default.temporaryDirectory.path)
        guard let free = attributes[.systemFreeSize] as? NSNumber, free.int64Value >= Int64(requiredBytes) else {
            throw SimilarPixelEraseError.storageUnavailable
        }
        let input = try PixelMappedBuffer(byteCount: dimensions.byteCount)
        let result = try PixelMappedBuffer(byteCount: dimensions.byteCount)
        defer { withExtendedLifetime((input, result)) {} }
        let count = dimensions.width * dimensions.height
        let pixels = input.pointer.assumingMemoryBound(to: UInt8.self)
        let output = result.pointer.assumingMemoryBound(to: UInt8.self)
        let width = dimensions.width
        let bandHeight = max(1, sourceBandBytes / dimensions.bytesPerRow)
        for y in stride(from: 0, to: dimensions.height, by: bandHeight) {
            try Task.checkCancellation()
            let height = min(bandHeight, dimensions.height - y)
            let band = try source.copyPixels(in: CGRect(x: rect.minX, y: rect.minY + CGFloat(y), width: rect.width, height: CGFloat(height)))
            guard let context = CGContext(data: input.pointer.advanced(by: y * dimensions.bytesPerRow),
                                          width: width, height: height, bitsPerComponent: 8, bytesPerRow: dimensions.bytesPerRow,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw AnnotationRenderError.contextCreationFailed
            }
            context.draw(band, in: CGRect(x: 0, y: 0, width: width, height: height))
            memcpy(output.advanced(by: y * dimensions.bytesPerRow), pixels.advanced(by: y * dimensions.bytesPerRow), height * dimensions.bytesPerRow)
            progress(0.15 * Double(y + height) / Double(dimensions.height))
        }
        if sensitivity == 0 {
            return try makePatch(result: result, dimensions: dimensions, sensitivity: sensitivity,
                                 changedPixelCount: 0, progress: progress)
        }
        let flags = try PixelMappedBuffer(byteCount: count)
        let queue = try PixelMappedBuffer(byteCount: count * MemoryLayout<Int32>.stride)
        defer { withExtendedLifetime((flags, queue)) {} }
        let visited = flags.pointer.assumingMemoryBound(to: UInt8.self)
        let members = queue.pointer.assumingMemoryBound(to: Int32.self)
        for index in 0..<count {
            if index % 16384 == 0 { try Task.checkCancellation() }
            let offset = index * 4, alpha = Int(pixels[offset + 3])
            if alpha > 0 {
                for c in 0..<3 { pixels[offset + c] = UInt8(min(255, (Int(pixels[offset + c]) * 255 + alpha / 2) / alpha)) }
            }
        }
        let thresholdSquared = pow(sensitivity / 100 * 255, 2) * 3
        var changedPixelCount = 0
        var processed = 0
        var lastProgress = -1
        for seed in 0..<count {
            if seed % 16384 == 0 { try Task.checkCancellation() }
            guard visited[seed] == 0 else { continue }
            visited[seed] = 1
            guard pixels[seed * 4 + 3] > 0 else { processed += 1; continue }
            members[0] = Int32(seed)
            var tail = 1, head = 0
            let sr = Int(pixels[seed * 4]), sg = Int(pixels[seed * 4 + 1]), sb = Int(pixels[seed * 4 + 2])
            var sums = (r: 0, g: 0, b: 0)
            func visit(_ neighbor: Int) {
                guard visited[neighbor] == 0, pixels[neighbor * 4 + 3] > 0 else { return }
                let dr = Int(pixels[neighbor * 4]) - sr
                let dg = Int(pixels[neighbor * 4 + 1]) - sg
                let db = Int(pixels[neighbor * 4 + 2]) - sb
                if Double(dr * dr + dg * dg + db * db) <= thresholdSquared {
                    visited[neighbor] = 1
                    members[tail] = Int32(neighbor)
                    tail += 1
                }
            }
            while head < tail {
                if head % 16384 == 0 {
                    try Task.checkCancellation()
                    let percentage = Int(100 * Double(processed + head) / Double(count))
                    if percentage != lastProgress { progress(0.15 + 0.7 * Double(percentage) / 100); lastProgress = percentage }
                }
                let index = Int(members[head]), x = index % width
                sums.r += Int(pixels[index * 4]); sums.g += Int(pixels[index * 4 + 1]); sums.b += Int(pixels[index * 4 + 2])
                if x > 0 { visit(index - 1) }
                if x + 1 < width { visit(index + 1) }
                if index >= width { visit(index - width) }
                if index + width < count { visit(index + width) }
                head += 1
            }
            let mean = [(sums.r + tail / 2) / tail, (sums.g + tail / 2) / tail, (sums.b + tail / 2) / tail]
            for position in 0..<tail {
                if position % 16384 == 0 { try Task.checkCancellation() }
                let offset = Int(members[position]) * 4, alpha = Int(pixels[offset + 3])
                var changed = false
                for c in 0..<3 {
                    let value = UInt8((mean[c] * alpha + 127) / 255)
                    changed = changed || output[offset + c] != value
                    output[offset + c] = value
                }
                if changed { changedPixelCount += 1 }
            }
            processed += tail
        }
        return try makePatch(result: result, dimensions: dimensions, sensitivity: sensitivity,
                             changedPixelCount: changedPixelCount, progress: progress)
    }

    private func makePatch(result: PixelMappedBuffer, dimensions: ScreenshotPixelDimensions, sensitivity: Double,
                           changedPixelCount: Int, progress: @Sendable (Double) -> Void) throws -> ScreenshotPixelPatch {
        try Task.checkCancellation()
        progress(0.9)
        let resultSource = MappedPixelSource(buffer: result, dimensions: dimensions)
        let preview = try ScreenshotEditorPreviewBuilder().makeBasePreview(document: ScreenshotDocument(baseImage: resultSource))
        progress(1)
        return try ScreenshotPixelPatch(image: resultSource.fullImage(), source: resultSource, preview: preview,
                                        sensitivity: sensitivity, changedPixelCount: changedPixelCount)
    }
}
