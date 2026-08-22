import Darwin
import Foundation

final class ToolBoxControlEndpointStore {
    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private let endpointFileURL: URL
    private let directoryURL: URL
    private let lockFileURL: URL
    private var lockFileDescriptor: Int32 = -1
    private var publishedFileIdentity: FileIdentity?

    init(endpointFileURL: URL) {
        self.endpointFileURL = endpointFileURL.standardizedFileURL
        self.directoryURL = endpointFileURL.deletingLastPathComponent().standardizedFileURL
        self.lockFileURL = directoryURL.appendingPathComponent("control.lock", isDirectory: false)
    }

    deinit {
        releaseLock()
    }

    func acquireLock() throws {
        guard lockFileDescriptor == -1 else { return }

        try preparePrivateDirectory()
        let descriptor = open(
            lockFileURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw ToolBoxControlTransportError.endpointLockUnavailable(lockFileURL.path)
        }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_uid == geteuid(),
              metadata.st_mode & S_IFMT == S_IFREG,
              fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0
        else {
            close(descriptor)
            throw ToolBoxControlTransportError.endpointLockUnavailable(lockFileURL.path)
        }
        lockFileDescriptor = descriptor
    }

    func publish(_ data: Data) throws {
        guard lockFileDescriptor >= 0 else {
            throw ToolBoxControlTransportError.endpointLockUnavailable(lockFileURL.path)
        }

        let temporaryURL = directoryURL.appendingPathComponent(
            ".control.endpoint.\(UUID().uuidString)",
            isDirectory: false
        )
        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw ToolBoxControlTransportError.endpointWriteFailed(endpointFileURL.path)
        }

        var shouldRemoveTemporaryFile = true
        var didReplaceEndpoint = false
        defer {
            close(descriptor)
            if shouldRemoveTemporaryFile {
                unlink(temporaryURL.path)
            }
        }

        do {
            try write(data, to: descriptor)
            guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0,
                  fsync(descriptor) == 0,
                  rename(temporaryURL.path, endpointFileURL.path) == 0
            else {
                throw ToolBoxControlTransportError.endpointWriteFailed(endpointFileURL.path)
            }
            shouldRemoveTemporaryFile = false
            didReplaceEndpoint = true
            try syncDirectory()

            guard let identity = fileIdentity(at: endpointFileURL),
                  isSecureRegularFile(at: endpointFileURL)
            else {
                unlink(endpointFileURL.path)
                throw ToolBoxControlTransportError.endpointWriteFailed(endpointFileURL.path)
            }
            publishedFileIdentity = identity
        } catch let error as ToolBoxControlTransportError {
            if didReplaceEndpoint {
                unlink(endpointFileURL.path)
            }
            throw error
        } catch {
            if didReplaceEndpoint {
                unlink(endpointFileURL.path)
            }
            throw ToolBoxControlTransportError.endpointWriteFailed(endpointFileURL.path)
        }
    }

    func removePublishedEndpoint() {
        defer { publishedFileIdentity = nil }
        guard let publishedFileIdentity,
              fileIdentity(at: endpointFileURL) == publishedFileIdentity
        else { return }

        unlink(endpointFileURL.path)
        try? syncDirectory()
    }

    func releaseLock() {
        guard lockFileDescriptor >= 0 else { return }
        flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
        lockFileDescriptor = -1
    }

    private func preparePrivateDirectory() throws {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ToolBoxControlTransportError.endpointDirectoryUnavailable(directoryURL.path)
        }

        var metadata = stat()
        guard lstat(directoryURL.path, &metadata) == 0,
              metadata.st_uid == geteuid(),
              metadata.st_mode & S_IFMT == S_IFDIR,
              chmod(directoryURL.path, mode_t(S_IRWXU)) == 0
        else {
            throw ToolBoxControlTransportError.insecureEndpointDirectory(directoryURL.path)
        }

        var verifiedMetadata = stat()
        guard lstat(directoryURL.path, &verifiedMetadata) == 0,
              verifiedMetadata.st_uid == geteuid(),
              verifiedMetadata.st_mode & S_IFMT == S_IFDIR,
              verifiedMetadata.st_mode & mode_t(0o077) == 0
        else {
            throw ToolBoxControlTransportError.insecureEndpointDirectory(directoryURL.path)
        }
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw ToolBoxControlTransportError.endpointWriteFailed(endpointFileURL.path)
                }
                offset += written
            }
        }
    }

    private func syncDirectory() throws {
        let descriptor = open(directoryURL.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ToolBoxControlTransportError.endpointWriteFailed(endpointFileURL.path)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw ToolBoxControlTransportError.endpointWriteFailed(endpointFileURL.path)
        }
    }

    private func fileIdentity(at url: URL) -> FileIdentity? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return nil }
        return FileIdentity(device: metadata.st_dev, inode: metadata.st_ino)
    }

    private func isSecureRegularFile(at url: URL) -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return false }
        return metadata.st_uid == geteuid()
            && metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_mode & mode_t(0o177) == 0
    }
}
