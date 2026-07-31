import CoreGraphics
import Darwin
import Foundation

final class ScrollCaptureStripStore {
    let sessionDirectory: URL
    let width: Int
    private(set) var logicalHeight: Int = 0

    private let budget: ScrollCaptureResourceBudget
    private var metadata: ScrollCaptureStripMetadata

    init(
        initialImage: CGImage,
        rootDirectory: URL = ScrollCaptureStripStore.defaultRootDirectory(),
        budget: ScrollCaptureResourceBudget = ScrollCaptureResourceBudget()
    ) throws {
        guard initialImage.width > 0, initialImage.height > 0 else {
            throw ScrollCaptureError.invalidStrip
        }
        self.budget = budget
        width = initialImage.width
        let sessionID = UUID()
        sessionDirectory = rootDirectory
            .appendingPathComponent("session-\(sessionID.uuidString)", isDirectory: true)
        metadata = ScrollCaptureStripMetadata(
            version: 2,
            sessionID: sessionID,
            width: initialImage.width,
            height: 0,
            maximumHeight: budget.maximumHeight,
            maximumRGBABytes: budget.maximumRGBABytes,
            strips: []
        )

        do {
            try FileManager.default.createDirectory(
                at: sessionDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try append(initialImage)
        } catch {
            try? FileManager.default.removeItem(at: sessionDirectory)
            throw error
        }
    }

    func append(_ image: CGImage) throws {
        guard image.width == width, image.height > 0 else {
            throw ScrollCaptureError.invalidStrip
        }
        let usage = try budget.validateAppend(
            width: width,
            currentHeight: logicalHeight,
            additionalRows: image.height
        )
        let data = try Self.rgbaData(from: image)
        let fileName = String(format: "strip-%06d.rgba", metadata.strips.count)
        let stripURL = sessionDirectory.appendingPathComponent(fileName)
        do {
            try Self.writeAtomically(data, to: stripURL)
            var candidate = metadata
            candidate.height = usage.height
            candidate.strips.append(
                ScrollCaptureStripRecord(
                    fileName: fileName,
                    startRow: logicalHeight,
                    height: image.height,
                    byteCount: data.count
                )
            )
            try Self.writeMetadata(candidate, in: sessionDirectory)
            metadata = candidate
            logicalHeight = usage.height
        } catch {
            try? FileManager.default.removeItem(at: stripURL)
            throw error as? ScrollCaptureError ?? .storageFailure
        }
    }

    func makeImageSource() throws -> ScrollCaptureImageSource {
        try ScrollCaptureImageSource(sessionDirectory: sessionDirectory)
    }

    static func defaultRootDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches
            .appendingPathComponent("ToolBox", isDirectory: true)
            .appendingPathComponent("ScrollCapture", isDirectory: true)
    }

    private static func rgbaData(from image: CGImage) throws -> Data {
        let dimensions = try ScreenshotPixelDimensions(
            size: CGSize(width: image.width, height: image.height)
        )
        var data = Data(count: dimensions.byteCount)
        let rendered = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: dimensions.width,
                      height: dimensions.height,
                      bitsPerComponent: 8,
                      bytesPerRow: dimensions.bytesPerRow,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else {
                return false
            }
            context.translateBy(x: 0, y: CGFloat(dimensions.height))
            context.scaleBy(x: 1, y: -1)
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: dimensions.width, height: dimensions.height)
            )
            return true
        }
        guard rendered else { throw ScrollCaptureError.storageFailure }
        return data
    }

    private static func writeMetadata(
        _ metadata: ScrollCaptureStripMetadata,
        in directory: URL
    ) throws {
        let data = try JSONEncoder().encode(metadata)
        try writeAtomically(data, to: directory.appendingPathComponent("metadata.json"))
    }

    private static func writeAtomically(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw ScrollCaptureError.storageFailure
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard chmod(temporary.path, S_IRUSR | S_IWUSR) == 0 else {
                throw ScrollCaptureError.storageFailure
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            synchronizeDirectory(destination.deletingLastPathComponent())
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw ScrollCaptureError.storageFailure
        }
    }

    private static func synchronizeDirectory(_ directory: URL) {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = fsync(descriptor)
    }
}

struct ScrollCaptureStripMetadata: Codable, Equatable {
    let version: Int
    let sessionID: UUID
    let width: Int
    var height: Int
    let maximumHeight: Int
    let maximumRGBABytes: Int
    var strips: [ScrollCaptureStripRecord]
}

struct ScrollCaptureStripRecord: Codable, Equatable {
    let fileName: String
    let startRow: Int
    let height: Int
    let byteCount: Int
}
