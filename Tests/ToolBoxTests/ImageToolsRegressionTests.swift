import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ToolBoxCore

struct ImageToolsRegressionTests {
    private final class Files {
        let directory: URL
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("image-regression-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }

        func image(_ name: String, format: ImageFormat = .jpeg, orientation: Int = 1, quality: Double = 0.9) throws -> URL {
            let url = directory.appendingPathComponent(name)
            let image = try #require(ImageFixtureFactory.makeImage(width: 240, height: 160))
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, format.imageIOTypeIdentifier! as CFString, 1, nil))
            let properties: [CFString: Any] = [
                kCGImagePropertyOrientation: orientation,
                kCGImageDestinationLossyCompressionQuality: quality,
                kCGImagePropertyDPIWidth: 144,
                kCGImagePropertyDPIHeight: 144,
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05"],
                kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 25.0, kCGImagePropertyGPSLatitudeRef: "N"],
            ]
            let metadata = CGImageMetadataCreateMutable()
            #expect(CGImageMetadataRegisterNamespaceForPrefix(metadata, "https://example.test/image/" as CFString, "test" as CFString, nil))
            #expect(CGImageMetadataSetValueWithPath(metadata, nil, "test:Note" as CFString, "keep this" as CFString))
            CGImageDestinationAddImageAndMetadata(destination, image, metadata, properties as CFDictionary)
            #expect(CGImageDestinationFinalize(destination))
            return url
        }
    }

    private func output(_ result: ImageJobResult) throws -> URL {
        switch result.outcome {
        case let .savedAs(url, _, _, _), let .converted(_, url, _, _, _): return url
        case .replaced: return result.source
        default:
            Issue.record("Unexpected outcome: \(result.outcome)")
            throw CocoaError(.fileReadUnknown)
        }
    }

    private func properties(_ url: URL) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func displayedPixels(_ url: URL) throws -> Data {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1000,
        ] as CFDictionary))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
                                             bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: image.width * image.height * 4)
    }

    @Test func explicitConversionMayGrowAndPreservesSourceWhenSavingAs() throws {
        let files = try Files()
        let source = try files.image("photo.jpg", quality: 0.1)
        let original = try Data(contentsOf: source)
        let result = ImagePipeline.process(url: source, options: .init(outputFormat: .png, naming: .suffix("-out")))
        let target = try output(result)
        #expect(target.pathExtension == "png")
        #expect(try Data(contentsOf: source) == original)
        #expect(try Data(contentsOf: target).count > original.count)
        #expect(result.savedBytes < 0)
    }

    @Test func pureCompressionStillKeepsSmallerOriginal() throws {
        let files = try Files()
        let source = try files.image("small.jpg", quality: 0.1)
        let original = try Data(contentsOf: source)
        let result = ImagePipeline.process(url: source, options: .init(level: 1))
        guard case .noBenefit = result.outcome else { Issue.record("\(result.outcome)"); return }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test(arguments: Array(1...8), [false, true])
    func orientationIsAppliedExactlyOnce(orientation: Int, strip: Bool) throws {
        let files = try Files()
        let source = try files.image("oriented.jpg", orientation: orientation)
        let before = try displayedPixels(source)
        let result = ImagePipeline.process(url: source, options: .init(outputFormat: .png, stripMetadata: strip, naming: .suffix("-out")))
        let target = try output(result)
        let props = try properties(target)
        #expect((props[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        #expect((props[kCGImagePropertyPixelWidth] as? Int) == (orientation >= 5 ? 160 : 240))
        #expect(try displayedPixels(target) == before)
    }

    @Test(arguments: [ImageFormat.jpeg, .png, .webp], [false, true])
    func metadataPolicyAndResizedDimensions(format: ImageFormat, strip: Bool) throws {
        let files = try Files()
        let source = try files.image("metadata.jpg", orientation: 6)
        let target = try output(ImagePipeline.process(url: source, options: .init(
            outputFormat: format, maxDimension: 120, stripMetadata: strip, naming: .suffix("-out")
        )))
        let props = try properties(target)
        #expect((props[kCGImagePropertyPixelWidth] as? Int) == 80)
        #expect((props[kCGImagePropertyPixelHeight] as? Int) == 120)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        let imageSource = try #require(CGImageSourceCreateWithURL(target as CFURL, nil))
        let metadata = CGImageSourceCopyMetadataAtIndex(imageSource, 0, nil)
        let note = metadata.flatMap { CGImageMetadataCopyStringValueWithPath($0, nil, "test:Note" as CFString) as String? }
        if strip {
            #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil)
            #expect(gps == nil)
            #expect(note == nil)
            // ImageIO synthesizes ProfileName=sRGB even without an embedded ICC.
            // Check the container marker instead of the decoder's inferred color space.
            let bytes = try Data(contentsOf: target)
            let marker = format == .jpeg ? "ICC_PROFILE" : format == .png ? "iCCP" : "ICCP"
            #expect(bytes.range(of: Data(marker.utf8)) == nil)
        } else {
            #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2020:01:02 03:04:05")
            #expect(exif?[kCGImagePropertyExifPixelXDimension] as? Int == 80)
            #expect(exif?[kCGImagePropertyExifPixelYDimension] as? Int == 120)
            #expect(gps?[kCGImagePropertyGPSLatitude] as? Double == 25)
            #expect(note == "keep this")
            // ImageIO reports WebP resolution in TIFF metadata on some OS versions.
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            #expect((props[kCGImagePropertyDPIWidth] as? Double ?? tiff?[kCGImagePropertyTIFFXResolution] as? Double) == 144)
            #expect(props[kCGImagePropertyProfileName] != nil)
        }
    }

    @Test func concurrentSiblingPublicationNeverOverwrites() async throws {
        let files = try Files()
        let source = try files.image("photo.jpg")
        let existing = files.directory.appendingPathComponent("photo.webp")
        try Data("existing".utf8).write(to: existing)
        let targets = try await withThrowingTaskGroup(of: (URL, Data).self) { group in
            for index in 0..<20 {
                group.addTask {
                    let data = Data("different content \(index)".utf8)
                    return (try AtomicFileReplacer.publishSibling(original: source, data: data, suffix: "", fileExtension: "webp"), data)
                }
            }
            var result: [(URL, Data)] = []
            for try await item in group { result.append(item) }
            return result
        }
        #expect(Set(targets.map(\.0)).count == 20)
        for (url, bytes) in targets { #expect(try Data(contentsOf: url) == bytes) }
        #expect(try Data(contentsOf: existing) == Data("existing".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.directory.path).allSatisfy { !$0.hasPrefix(".toolbox-") })
    }

    @Test func failedSourceDeletionKeepsBothFilesAndReportsTruth() throws {
        let files = try Files()
        let source = try files.image("photo.jpg")
        let original = try Data(contentsOf: source)
        let result = ImagePipeline.process(url: source, options: .init(outputFormat: .png), removeSource: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        guard case let .sourceRetained(target, _, _, _, detail) = result.outcome else {
            Issue.record("\(result.outcome)"); return
        }
        #expect(detail.contains("源文件未删除"))
        #expect(try Data(contentsOf: source) == original)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func failedPublicationLeavesOriginalAndNoTemporaryFile() throws {
        let files = try Files()
        let source = try files.image("photo.jpg")
        let original = try Data(contentsOf: source)
        let result = ImagePipeline.process(url: source, options: .init(outputFormat: .png, naming: .suffix("/missing/out")))
        guard case .failed = result.outcome else { Issue.record("\(result.outcome)"); return }
        #expect(try Data(contentsOf: source) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.directory.path) == ["photo.jpg"])
    }

    @Test func cancellationAtCommitLeavesFilesUnchanged() async throws {
        let files = try Files()
        for hash in [false, true] {
            let source = try files.image(hash ? "hash.jpg" : "convert.jpg")
            let original = try Data(contentsOf: source)
            // The hook is exactly before the cancellation check and any publication.
            let task = Task {
                let cancel: () -> Void = { withUnsafeCurrentTask { $0?.cancel() } }
                if hash {
                    let result = ImageHashChanger.rehash(url: source, beforeCommit: cancel)
                    guard case .failed = result.outcome else { Issue.record("\(result.outcome)"); return }
                } else {
                    let result = ImagePipeline.process(url: source, options: .init(outputFormat: .png), beforeCommit: cancel)
                    guard case .failed = result.outcome else { Issue.record("\(result.outcome)"); return }
                }
            }
            await task.value
            #expect(try Data(contentsOf: source) == original)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.directory.path).sorted() == ["convert.jpg", "hash.jpg"])
    }

    @Test func alreadyCancelledBatchDoesNotStart() async throws {
        let files = try Files()
        let source = try files.image("photo.jpg")
        let original = try Data(contentsOf: source)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(await ImageHashChanger.rehash(urls: [source]).isEmpty)
            #expect(await ImagePipeline.process(urls: [source], options: .init()).isEmpty)
        }
        await task.value
        #expect(try Data(contentsOf: source) == original)
    }
}

extension ImageToolsRegressionTests {
    @Test(arguments: [ImageFormat.tiff, .heic, .avif])
    func repeatedHashStaysBounded(format: ImageFormat) throws {
        guard ImageCapabilities.canImageIOEncode(format) else { return }
        let files = try Files()
        let source = try files.image("photo.\(format.rawValue)", format: format)
        let original = try Data(contentsOf: source)
        var data = try ImageHashChanger.mutate(data: original, format: format)
        let size = data.count
        for _ in 0..<20 {
            let next = try ImageHashChanger.mutate(data: data, format: format)
            #expect(next.count == size)
            #expect(next != data)
            try ImageHashChanger.validateVisualEquality(original: original, mutated: next, format: format)
            data = next
        }
    }

    @Test func tiffLegacyCleanupAndUnrecognizedMarkerPreservation() throws {
        let files = try Files()
        let source = try files.image("photo.tiff", format: .tiff)
        let original = try Data(contentsOf: source)
        let marker = ImageHashChanger.injectionMarker
        let payload = marker + Data(repeating: 0x41, count: 24)
        let clean = try TIFFHashMutator.mutate(original, payload: payload)
        let legacy = original + marker + marker + marker + Data(repeating: 0x42, count: 24) + Data([10])
        #expect(try TIFFHashMutator.mutate(legacy, payload: payload) == clean)
        let unknownTail = original + marker + Data("not our footer\n".utf8)
        #expect(try TIFFHashMutator.mutate(unknownTail, payload: payload).starts(with: unknownTail))
    }

    @Test func bmffPreservesNonTailFreeBoxAndRejectsOversizedLength() throws {
        let payload = ImageHashChanger.injectionMarker + Data(repeating: 65, count: 24)
        let head = Data([0, 0, 0, 12]) + Data("ftypheic".utf8)
        let first = try BMFFHashMutator.mutate(head, payload: payload)
        let trailing = Data([0, 0, 0, 12]) + Data("freekeep".utf8)
        let withUserTail = first + trailing
        #expect(try BMFFHashMutator.mutate(withUserTail, payload: payload).starts(with: withUserTail))
        let malformed = Data([0, 0, 0, 1]) + Data("free".utf8) + Data(repeating: 255, count: 8)
        #expect(throws: (any Error).self) { try BMFFHashMutator.mutate(malformed, payload: payload) }
    }

    @Test(arguments: [ImageFormat.gif, .tiff])
    func hashKeepsAllAnimationOrPageFrames(format: ImageFormat) throws {
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, format.imageIOTypeIdentifier! as CFString, 3, nil))
        for width in [24, 25, 26] {
            let image = try #require(ImageFixtureFactory.makeImage(width: width, height: 24))
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2],
            ] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        let original = output as Data
        let mutated = try ImageHashChanger.mutate(data: original, format: format)
        try ImageHashChanger.validateVisualEquality(original: original, mutated: mutated, format: format)
        let source = try #require(CGImageSourceCreateWithData(mutated as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 3)
    }
}

extension ImageToolsRegressionTests {
    @Test func cancellationAtBatchBoundaryDoesNotTouchLaterFiles() async throws {
        let files = try Files()
        let urls = try (0..<8).map { try files.image("batch-\($0).jpg") }
        let before = try urls.map { try Data(contentsOf: $0) }
        let task = Task {
            await ImageHashChanger.rehash(urls: urls) { completed, _ in
                if completed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let results = await task.value
        let width = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))
        #expect(results.count == width)
        for index in width..<urls.count {
            #expect(try Data(contentsOf: urls[index]) == before[index])
        }
    }

    @Test func sameStemConversionsBothSurvive() async throws {
        let files = try Files()
        let jpeg = try files.image("photo.jpg", quality: 0.1)
        let tiff = try files.image("photo.tiff", format: .tiff)
        let before = try [jpeg, tiff].map { try displayedPixels($0) }
        let results = await ImagePipeline.process(urls: [jpeg, tiff], options: .init(outputFormat: .png))
        let targets = try results.map(output)
        #expect(Set(targets).count == 2)
        for index in targets.indices { #expect(try displayedPixels(targets[index]) == before[index]) }
        #expect(!FileManager.default.fileExists(atPath: jpeg.path))
        #expect(!FileManager.default.fileExists(atPath: tiff.path))
    }
}
