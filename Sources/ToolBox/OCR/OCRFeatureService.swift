import Foundation

enum OCRFeatureServiceError: Error, Equatable {
    case modelUnavailable(PPOCRv6Profile)
    case modelNotInstalled(PPOCRv6Profile)
}

struct OCRModelDescriptor: Equatable, Sendable {
    let profile: PPOCRv6Profile
    let downloadByteCount: Int64
    let state: OCRModelState
}

protocol OCRFeatureServing: Sendable {
    func descriptor(for profile: PPOCRv6Profile) async throws -> OCRModelDescriptor
    @discardableResult
    func install(profile: PPOCRv6Profile, userConsented: Bool) async throws -> URL
    func recognize(
        source: ScreenshotImageSource,
        settings: OCRSettings
    ) async throws -> TextOCRDocument
}

actor OCRFeatureService: OCRFeatureServing {
    static let shared = OCRFeatureService()

    private struct EngineKey: Hashable {
        let profile: PPOCRv6Profile
        let provider: OCRExecutionProvider
    }

    private struct EngineEntry {
        let key: EngineKey
        let engine: LocalPaddleOCREngine
        let lease: OCRModelLease
    }

    private let catalogLoader: OCRModelCatalogLoader
    private let store: OCRModelStore
    private let downloadManager: OCRModelDownloadManager
    private var activeEngine: EngineEntry?

    init(
        rootDirectory: URL = OCRFeatureService.defaultModelRootDirectory,
        catalogLoader: OCRModelCatalogLoader = .shipped,
        downloader: OCRModelFileDownloading = URLSessionOCRModelFileDownloader()
    ) {
        self.catalogLoader = catalogLoader
        store = OCRModelStore(rootDirectory: rootDirectory)
        downloadManager = OCRModelDownloadManager(store: store, downloader: downloader)
    }

    func descriptor(for profile: PPOCRv6Profile) throws -> OCRModelDescriptor {
        let manifest = try manifest(for: profile)
        return OCRModelDescriptor(
            profile: profile,
            downloadByteCount: manifest.files.reduce(0) { $0 + $1.byteCount },
            state: try store.state(for: manifest)
        )
    }

    @discardableResult
    func install(profile: PPOCRv6Profile, userConsented: Bool) async throws -> URL {
        let manifest = try manifest(for: profile)
        if activeEngine?.key.profile == profile {
            activeEngine = nil
        }
        return try await downloadManager.install(
            manifest: manifest,
            userConsented: userConsented
        )
    }

    func recognize(
        source: ScreenshotImageSource,
        settings: OCRSettings
    ) async throws -> TextOCRDocument {
        guard settings.pipeline == .ppOCRv6 else {
            throw OCRSettingsError.unavailablePipeline
        }
        let manifest = try manifest(for: settings.profile)
        guard try store.state(for: manifest) == .ready else {
            throw OCRFeatureServiceError.modelNotInstalled(settings.profile)
        }
        let key = EngineKey(
            profile: settings.profile,
            provider: settings.executionProvider
        )
        let entry: EngineEntry
        if let activeEngine, activeEngine.key == key {
            entry = activeEngine
        } else {
            let lease = try store.acquireLease(for: manifest)
            let created = try LocalPaddleOCREngine(
                modelDirectory: lease.directory,
                provider: settings.executionProvider
            )
            entry = EngineEntry(key: key, engine: created, lease: lease)
            activeEngine = entry
        }
        return try await entry.engine.recognize(source: source)
    }

    private func manifest(for profile: PPOCRv6Profile) throws -> OCRModelManifest {
        let catalog = try catalogLoader.loadBundledCatalog()
        guard let manifest = catalog.models.first(where: {
            $0.pipeline == .ppOCRv6 && $0.profile == profile
        }) else { throw OCRFeatureServiceError.modelUnavailable(profile) }
        return manifest
    }

    private static let defaultModelRootDirectory: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ToolBox", isDirectory: true)
            .appendingPathComponent("OCRModels", isDirectory: true)
    }()
}
