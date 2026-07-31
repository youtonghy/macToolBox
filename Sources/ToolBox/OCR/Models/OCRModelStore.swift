import CryptoKit
import Darwin
import Foundation

enum OCRModelState: Equatable, Sendable {
    case notInstalled
    case downloading(Double)
    case validating
    case ready
    case corrupt
    case updateAvailable
    case failed
}

enum OCRModelStoreError: Error, Equatable {
    case unsafeStagingDirectory
    case unexpectedFile
    case missingFile
    case unsupportedFileType
    case lengthMismatch
    case hashMismatch
    case corruptModel
    case modelInUse
}

final class OCRModelLease: @unchecked Sendable {
    let directory: URL
    private let release: () -> Void

    fileprivate init(directory: URL, release: @escaping () -> Void) {
        self.directory = directory
        self.release = release
    }

    deinit { release() }
}

final class OCRModelStore: @unchecked Sendable {
    let rootDirectory: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var leaseCounts: [String: Int] = [:]

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager
    }

    func makeStagingDirectory(for manifest: OCRModelManifest) throws -> URL {
        try manifest.validate()
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let directory = rootDirectory.appendingPathComponent(
            ".staging-\(manifest.id)-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    func state(for manifest: OCRModelManifest) throws -> OCRModelState {
        let directory = installedDirectory(for: manifest)
        guard fileManager.fileExists(atPath: directory.path) else { return .notInstalled }
        do {
            try verify(manifest: manifest, directory: directory)
            return .ready
        } catch {
            return .corrupt
        }
    }

    @discardableResult
    func publish(manifest: OCRModelManifest, stagingDirectory: URL) throws -> URL {
        try manifest.validate()
        let staging = stagingDirectory.standardizedFileURL
        guard staging.deletingLastPathComponent() == rootDirectory,
              staging.lastPathComponent.hasPrefix(".staging-\(manifest.id)-")
        else {
            throw OCRModelStoreError.unsafeStagingDirectory
        }
        try verify(manifest: manifest, directory: staging)
        for file in manifest.files {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: staging.appendingPathComponent(file.relativePath).path
            )
        }
        let destination = installedDirectory(for: manifest)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if fileManager.fileExists(atPath: destination.path) {
            if try state(for: manifest) == .ready {
                try fileManager.removeItem(at: staging)
                return destination
            }
            throw OCRModelStoreError.corruptModel
        }
        try fileManager.moveItem(at: staging, to: destination)
        return destination
    }

    func acquireLease(for manifest: OCRModelManifest) throws -> OCRModelLease {
        guard try state(for: manifest) == .ready else { throw OCRModelStoreError.corruptModel }
        let directory = installedDirectory(for: manifest)
        let key = directory.path
        lock.lock()
        leaseCounts[key, default: 0] += 1
        lock.unlock()
        return OCRModelLease(directory: directory) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let next = max(0, (self.leaseCounts[key] ?? 1) - 1)
            if next == 0 { self.leaseCounts.removeValue(forKey: key) }
            else { self.leaseCounts[key] = next }
            self.lock.unlock()
        }
    }

    func installedModelDirectory(for manifest: OCRModelManifest) throws -> URL {
        guard try state(for: manifest) == .ready else { throw OCRModelStoreError.corruptModel }
        return installedDirectory(for: manifest)
    }

    func delete(manifest: OCRModelManifest) throws {
        let directory = installedDirectory(for: manifest)
        lock.lock()
        let inUse = (leaseCounts[directory.path] ?? 0) > 0
        lock.unlock()
        guard !inUse else { throw OCRModelStoreError.modelInUse }
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        let parent = directory.deletingLastPathComponent()
        if (try? fileManager.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
            try? fileManager.removeItem(at: parent)
        }
    }

    func removeAbandonedStagingDirectories() throws {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return }
        for item in try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) where item.lastPathComponent.hasPrefix(".staging-") {
            try fileManager.removeItem(at: item)
        }
    }

    private func installedDirectory(for manifest: OCRModelManifest) -> URL {
        rootDirectory
            .appendingPathComponent(manifest.id, isDirectory: true)
            .appendingPathComponent(manifest.version, isDirectory: true)
    }

    private func verify(manifest: OCRModelManifest, directory: URL) throws {
        let expected = Set(manifest.files.map(\.relativePath))
        var actual = Set<String>()
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { throw OCRModelStoreError.missingFile }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw OCRModelStoreError.unsupportedFileType }
            guard values.isRegularFile == true else { continue }
            let base = directory.standardizedFileURL.path + "/"
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { throw OCRModelStoreError.unexpectedFile }
            actual.insert(String(path.dropFirst(base.count)))
        }
        guard actual == expected else {
            throw actual.isSuperset(of: expected)
                ? OCRModelStoreError.unexpectedFile
                : OCRModelStoreError.missingFile
        }
        for file in manifest.files {
            let url = directory.appendingPathComponent(file.relativePath)
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
                throw OCRModelStoreError.unsupportedFileType
            }
            guard (attributes[.size] as? NSNumber)?.int64Value == file.byteCount else {
                throw OCRModelStoreError.lengthMismatch
            }
            guard try Self.sha256(of: url) == file.sha256 else {
                throw OCRModelStoreError.hashMismatch
            }
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: 1_024 * 1_024)
            guard !data.isEmpty else { return false }
            digest.update(data: data)
            return true
        }) {}
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
