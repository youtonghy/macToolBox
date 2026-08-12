import Foundation

enum OCRModelDownloadError: Error, Equatable {
    case consentRequired
    case invalidHTTPResponse
    case unexpectedRedirect
    case insufficientDiskSpace
    case downloadFailed
}

protocol OCRModelFileDownloading: Sendable {
    func download(_ url: URL) async throws -> URL
    func download(_ url: URL, expectedByteCount: Int64?) async throws -> URL
}

extension OCRModelFileDownloading {
    func download(_ url: URL, expectedByteCount: Int64?) async throws -> URL {
        try await download(url)
    }
}

private final class OCRModelRedirectPolicy: NSObject, URLSessionTaskDelegate {
    private let allowedHosts: Set<String> = [
        "huggingface.co",
        "cdn-lfs.huggingface.co",
    ]

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let host = request.url?.host?.lowercased(),
              let scheme = request.url?.scheme?.lowercased(),
              scheme == "https",
              allowedHosts.contains(host)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

struct URLSessionOCRModelFileDownloader: OCRModelFileDownloading, @unchecked Sendable {
    let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? Self.makeSession()
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 30 * 60
        configuration.waitsForConnectivity = true
        return URLSession(
            configuration: configuration,
            delegate: OCRModelRedirectPolicy(),
            delegateQueue: nil
        )
    }

    func download(_ url: URL) async throws -> URL {
        try await download(url, expectedByteCount: nil)
    }

    func download(_ url: URL, expectedByteCount: Int64?) async throws -> URL {
        var lastError: Error = OCRModelDownloadError.downloadFailed
        for attempt in 0..<3 {
            do {
                let (temporary, response) = try await session.download(from: url)
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode)
                else {
                    try? FileManager.default.removeItem(at: temporary)
                    throw OCRModelDownloadError.invalidHTTPResponse
                }
                if let expected = expectedByteCount,
                   response.expectedContentLength > 0,
                   response.expectedContentLength != expected {
                    try? FileManager.default.removeItem(at: temporary)
                    throw OCRModelDownloadError.invalidHTTPResponse
                }
                return temporary
            } catch OCRModelDownloadError.invalidHTTPResponse {
                throw OCRModelDownloadError.invalidHTTPResponse
            } catch OCRModelDownloadError.unexpectedRedirect {
                throw OCRModelDownloadError.unexpectedRedirect
            } catch {
                lastError = error
                if attempt < 2 {
                    let delay: UInt64 = 1_000_000_000 << UInt64(attempt)
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }
        throw lastError
    }
}

actor OCRModelDownloadManager {
    private let store: OCRModelStore
    private let downloader: OCRModelFileDownloading

    init(store: OCRModelStore, downloader: OCRModelFileDownloading = URLSessionOCRModelFileDownloader()) {
        self.store = store
        self.downloader = downloader
    }

    func install(manifest: OCRModelManifest, userConsented: Bool) async throws -> URL {
        guard userConsented else { throw OCRModelDownloadError.consentRequired }
        try manifest.validate()
        let state = try store.state(for: manifest)
        if state == .ready {
            return try store.installedModelDirectory(for: manifest)
        }
        if state == .corrupt {
            try store.delete(manifest: manifest)
        }
        try ensureDiskCapacity(for: manifest)
        let staging = try store.makeStagingDirectory(for: manifest)
        do {
            for file in manifest.files {
                try Task.checkCancellation()
                let temporary = try await downloader.download(file.url, expectedByteCount: file.byteCount)
                defer { try? FileManager.default.removeItem(at: temporary) }
                let destination = staging.appendingPathComponent(file.relativePath)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            return try store.publish(manifest: manifest, stagingDirectory: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private func ensureDiskCapacity(for manifest: OCRModelManifest) throws {
        try FileManager.default.createDirectory(
            at: store.rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let totalBytes = manifest.files.reduce(into: Int64(0)) { $0 += $1.byteCount }
        let values = try store.rootDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        guard available >= totalBytes else {
            throw OCRModelDownloadError.insufficientDiskSpace
        }
    }
}
