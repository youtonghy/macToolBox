import Foundation

enum OCRFeatureServiceError: Error, Equatable {
    case modelUnavailable(OCRModelSelection)
    case modelNotInstalled(OCRModelSelection)
    case workerUnavailable
}

struct OCRModelDescriptor: Equatable, Sendable {
    let selection: OCRModelSelection
    let displayName: String
    let downloadByteCount: Int64
    let state: OCRModelState

    init(
        selection: OCRModelSelection,
        displayName: String? = nil,
        downloadByteCount: Int64,
        state: OCRModelState
    ) {
        self.selection = selection
        self.displayName = displayName ?? "\(selection.pipeline.displayName) \(selection.variantID)"
        self.downloadByteCount = downloadByteCount
        self.state = state
    }

    init(profile: PPOCRv6Profile, downloadByteCount: Int64, state: OCRModelState) {
        self.init(
            selection: OCRModelSelection(pipeline: .ppOCRv6, variantID: profile.rawValue),
            displayName: "PP-OCRv6 \(profile.rawValue.capitalized)",
            downloadByteCount: downloadByteCount,
            state: state
        )
    }

    var profile: PPOCRv6Profile? {
        guard selection.pipeline == .ppOCRv6 else { return nil }
        return PPOCRv6Profile(rawValue: selection.variantID)
    }
}

protocol OCRFeatureServing: Sendable {
    func availableSelections() async throws -> [OCRModelSelection]
    func descriptor(for selection: OCRModelSelection) async throws -> OCRModelDescriptor
    @discardableResult
    func install(selection: OCRModelSelection, userConsented: Bool) async throws -> URL
    func recognize(
        source: ScreenshotImageSource,
        settings: OCRSettings
    ) async throws -> OCRResult
}

extension OCRFeatureServing {
    func availableSelections() async throws -> [OCRModelSelection] {
        OCRPipelineID.allCases.flatMap { pipeline in
            pipeline.knownVariantIDs.sorted().map {
                OCRModelSelection(pipeline: pipeline, variantID: $0)
            }
        }
    }

    func descriptor(for profile: PPOCRv6Profile) async throws -> OCRModelDescriptor {
        try await descriptor(for: OCRModelSelection(pipeline: .ppOCRv6, variantID: profile.rawValue))
    }

    @discardableResult
    func install(profile: PPOCRv6Profile, userConsented: Bool) async throws -> URL {
        try await install(
            selection: OCRModelSelection(pipeline: .ppOCRv6, variantID: profile.rawValue),
            userConsented: userConsented
        )
    }
}

actor OCRFeatureService: OCRFeatureServing {
    static let shared = OCRFeatureService()

    private struct EngineKey: Hashable {
        let selection: OCRModelSelection
        let provider: OCRExecutionProvider
        let version: String
    }

    private struct EngineEntry {
        let key: EngineKey
        let engine: LocalPaddleOCREngine
        let lease: OCRModelLease
    }

    private let catalogLoader: OCRModelCatalogLoader
    private let catalogOverride: OCRModelCatalog?
    private let store: OCRModelStore
    private let downloadManager: OCRModelDownloadManager
    private let worker: OCRWorkerRunning?
    private var activeEngine: EngineEntry?

    init(
        rootDirectory: URL = OCRFeatureService.defaultModelRootDirectory,
        catalogLoader: OCRModelCatalogLoader = .shipped,
        catalogOverride: OCRModelCatalog? = nil,
        downloader: OCRModelFileDownloading = URLSessionOCRModelFileDownloader(),
        worker: OCRWorkerRunning? = nil,
        workerLocator: OCRWorkerExecutableLocator = OCRWorkerExecutableLocator()
    ) {
        self.catalogLoader = catalogLoader
        self.catalogOverride = catalogOverride
        store = OCRModelStore(rootDirectory: rootDirectory)
        downloadManager = OCRModelDownloadManager(store: store, downloader: downloader)
        self.worker = worker ?? (try? OCRWorkerRunning(locator: workerLocator))
    }

    func availableSelections() async throws -> [OCRModelSelection] {
        let models = try catalog().models
        var seen = Set<OCRModelSelection>()
        return models.compactMap { manifest in
            let selection = manifest.selection
            guard selection.isKnownVariant,
                  selection.pipeline == .ppOCRv6 || worker != nil,
                  seen.insert(selection).inserted
            else { return nil }
            return selection
        }
    }

    func descriptor(for selection: OCRModelSelection) throws -> OCRModelDescriptor {
        guard selection.isKnownVariant else {
            throw OCRFeatureServiceError.modelUnavailable(selection)
        }
        let manifest = try manifest(for: selection)
        return OCRModelDescriptor(
            selection: selection,
            displayName: manifest.displayName ?? selectionDisplayName(selection),
            downloadByteCount: manifest.files.reduce(0) { $0 + $1.byteCount },
            state: try store.state(for: manifest)
        )
    }

    @discardableResult
    func install(selection: OCRModelSelection, userConsented: Bool) async throws -> URL {
        guard selection.isKnownVariant else {
            throw OCRFeatureServiceError.modelUnavailable(selection)
        }
        let manifest = try manifest(for: selection)
        if activeEngine?.key.selection == selection { activeEngine = nil }
        return try await downloadManager.install(
            manifest: manifest,
            userConsented: userConsented
        )
    }

    func recognize(
        source: ScreenshotImageSource,
        settings: OCRSettings
    ) async throws -> OCRResult {
        let settings = settings.normalizedForRuntime
        let selection = settings.selection
        guard selection.isKnownVariant else {
            throw OCRFeatureServiceError.modelUnavailable(selection)
        }
        if selection.pipeline == .ppOCRv6 {
            let manifest = try manifest(for: selection)
            guard try store.state(for: manifest) == .ready else {
                throw OCRFeatureServiceError.modelNotInstalled(selection)
            }
            let key = EngineKey(
                selection: selection,
                provider: settings.executionProvider,
                version: manifest.version
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
            return .text(try await entry.engine.recognize(source: source))
        }

        guard let worker else { throw OCRFeatureServiceError.workerUnavailable }
        let manifest = try manifest(for: selection)
        guard try store.state(for: manifest) == .ready else {
            throw OCRFeatureServiceError.modelNotInstalled(selection)
        }
        let lease = try store.acquireLease(for: manifest)
        return try await worker.run(
            source: source,
            selection: selection,
            modelDirectory: lease.directory
        )
    }

    private func manifest(for selection: OCRModelSelection) throws -> OCRModelManifest {
        let catalog = try catalog()
        guard let manifest = catalog.models.first(where: { $0.selection == selection }) else {
            throw OCRFeatureServiceError.modelUnavailable(selection)
        }
        return manifest
    }

    private func catalog() throws -> OCRModelCatalog {
        if let catalogOverride {
            try catalogOverride.validate()
            return catalogOverride
        }
        return try catalogLoader.loadBundledCatalog()
    }

    private func selectionDisplayName(_ selection: OCRModelSelection) -> String {
        switch selection.pipeline {
        case .ppOCRv6: "PP-OCRv6 \(selection.variantID.capitalized)"
        case .ppStructureV3: "PP-StructureV3"
        case .paddleOCRVL: "PaddleOCR-VL \(selection.variantID)"
        }
    }

    private static let defaultModelRootDirectory: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ToolBox", isDirectory: true)
            .appendingPathComponent("OCRModels", isDirectory: true)
    }()
}
