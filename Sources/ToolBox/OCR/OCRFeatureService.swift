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
        try? store.removeAbandonedStagingDirectories(maximumAge: 60 * 60)
        downloadManager = OCRModelDownloadManager(store: store, downloader: downloader)
        self.worker = worker ?? (try? OCRWorkerRunning(locator: workerLocator))
    }

    func availableSelections() async throws -> [OCRModelSelection] {
        let models = try catalog().models
        var seen = Set<OCRModelSelection>()
        var selections = models.compactMap { manifest -> OCRModelSelection? in
            let selection = manifest.selection
            guard selection.isKnownVariant,
                  selection.pipeline == .ppOCRv6 || worker != nil,
                  seen.insert(selection).inserted
            else { return nil }
            return selection
        }
        
        // System Vision is always available (no catalog entry, no download)
        let systemVision = OCRModelSelection(pipeline: .systemVision, variantID: "default")
        if !seen.contains(systemVision) {
            selections.insert(systemVision, at: 0)
        }
        
        return selections
    }

    func descriptor(for selection: OCRModelSelection) throws -> OCRModelDescriptor {
        guard selection.isKnownVariant else {
            throw OCRFeatureServiceError.modelUnavailable(selection)
        }
        
        // System Vision pipeline: always ready, no download
        if selection.pipeline == .systemVision {
            return OCRModelDescriptor(
                selection: selection,
                displayName: selectionDisplayName(selection),
                downloadByteCount: 0,
                state: .ready
            )
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
        
        // System Vision pipeline: no-op install (always ready)
        if selection.pipeline == .systemVision {
            return FileManager.default.temporaryDirectory
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
        
        // System Vision pipeline: no download, no worker, always available
        if selection.pipeline == .systemVision {
            let document = try await recognizeWithSystemVision(
                engine: SystemVisionOCREngine(),
                source: source
            )
            return .text(document)
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

    /// Vision has no built-in tiling: feeding a near-512 MiB long screenshot as
    /// one CGImage would materialize it (plus Vision's own buffers) on the heap.
    /// Tile with the same planner the local Paddle engine uses, then merge
    /// tile-local lines back into full-image coordinates.
    private func recognizeWithSystemVision(
        engine: SystemVisionOCREngine,
        source: ScreenshotImageSource
    ) async throws -> TextOCRDocument {
        let planner = try PaddleOCRTilePlanner()
        let fullSize = source.pixelSize
        let tiles = planner.tiles(for: fullSize)
        guard !tiles.isEmpty else {
            throw OCRFeatureServiceError.modelUnavailable(
                OCRModelSelection(pipeline: .systemVision, variantID: "default")
            )
        }
        var lines: [OCRTextLine] = []
        for tile in tiles {
            try Task.checkCancellation()
            let image = try source.copyPixels(in: tile)
            let document = try await engine.recognize(image: image)
            lines.append(contentsOf: Self.rebased(document.lines, from: tile, to: fullSize))
        }
        return TextOCRDocument(lines: Self.deduplicated(lines))
    }

    /// Maps tile-normalized polygons (0…1 within the tile) to full-image
    /// normalized coordinates.
    static func rebased(
        _ lines: [OCRTextLine],
        from tile: CGRect,
        to fullSize: CGSize
    ) -> [OCRTextLine] {
        lines.compactMap { line in
            let polygon = line.normalizedPolygon.map { point in
                CGPoint(
                    x: (tile.minX + point.x * tile.width) / fullSize.width,
                    y: (tile.minY + point.y * tile.height) / fullSize.height
                )
            }
            return try? OCRTextLine(
                text: line.text,
                confidence: line.confidence,
                normalizedPolygon: polygon
            )
        }
    }

    /// Drops near-identical lines detected twice in overlapping tile regions.
    static func deduplicated(_ lines: [OCRTextLine]) -> [OCRTextLine] {
        var accepted: [OCRTextLine] = []
        for line in lines {
            let isDuplicate = accepted.contains(where: { existing in
                existing.text == line.text
                    && intersectionOverUnion(of: existing.bounds, and: line.bounds) > 0.5
            })
            if !isDuplicate {
                accepted.append(line)
            }
        }
        return accepted
    }

    static func intersectionOverUnion(of lhs: CGRect, and rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        let unionArea = lhs.width * lhs.height
            + rhs.width * rhs.height
            - intersection.width * intersection.height
        guard unionArea > 0 else { return 0 }
        return (intersection.width * intersection.height) / unionArea
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
        case .systemVision: "System OCR"
        }
    }

    private static let defaultModelRootDirectory: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ToolBox", isDirectory: true)
            .appendingPathComponent("OCRModels", isDirectory: true)
    }()
}
