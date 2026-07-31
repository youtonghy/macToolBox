import Foundation

enum OCRModelDownloadError: Error, Equatable {
    case consentRequired
    case invalidHTTPResponse
}

protocol OCRModelFileDownloading: Sendable {
    func download(_ url: URL) async throws -> URL
}

struct URLSessionOCRModelFileDownloader: OCRModelFileDownloading, @unchecked Sendable {
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func download(_ url: URL) async throws -> URL {
        let (temporary, response) = try await session.download(from: url)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode)
        else { throw OCRModelDownloadError.invalidHTTPResponse }
        return temporary
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
        let staging = try store.makeStagingDirectory(for: manifest)
        do {
            for file in manifest.files {
                try Task.checkCancellation()
                let temporary = try await downloader.download(file.url)
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
}
