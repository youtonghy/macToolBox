import Foundation
import AppKit
import Combine

/// Coordinates clipboard monitoring and history panel display
@MainActor
final class ClipboardCoordinator: ObservableObject {
    private let store: ClipboardStore
    private let captureSerializer = CaptureHashSerializer()
    private var pollTimer: Timer?
    private var lastChangeCount: Int = 0
    private(set) var panelController: ClipboardPanelController?
    private var storeCancellable: AnyCancellable?

    /// True while monitoring is active; gates both capture and the panel so
    /// the feature toggle fully disables clipboard access.
    private(set) var isMonitoring = false

    /// Monotonic monitoring-session generation. Capture tasks carry the value
    /// from their session; a commit from a stale session is dropped even if
    /// monitoring was restarted in the meantime (stop → start).
    private var monitoringGeneration = 0

    init(store: ClipboardStore) {
        self.store = store
        let timeLimit = Self.loadTimeLimit()
        let memoryLimit = Self.loadMemoryLimit()
        self.timeLimit = timeLimit
        self.memoryLimit = memoryLimit
        // didSet observers do not run during init, so apply to the store here.
        store.setTimeLimit(timeLimit)
        store.setMemoryLimit(memoryLimit)
        // Forward store mutations so usage/count stay fresh in Settings.
        storeCancellable = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
            }
        }
    }

    convenience init() {
        self.init(store: ClipboardStore())
    }

    /// Start monitoring clipboard changes
    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        monitoringGeneration += 1 // new session: stale capture tasks become invalid
        lastChangeCount = NSPasteboard.general.changeCount
        captureCurrentPasteboard()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPasteboardChange()
            }
        }
    }

    /// Stop monitoring clipboard changes
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        isMonitoring = false
        monitoringGeneration += 1 // drop in-flight capture commits from this session
        // A presented panel could still paste after the feature was disabled;
        // closing it also cancels any in-flight permission wait.
        panelController?.close()
    }

    func showPanel() {
        guard isMonitoring else { return }
        captureCurrentPasteboard()
        if panelController == nil { panelController = ClipboardPanelController(store: store) }
        panelController?.present()
    }

    var items: [ClipboardItem] { store.items }

    private func checkPasteboardChange() {
        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount

        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount

        captureCurrentPasteboard()
    }

    private func captureCurrentPasteboard() {
        guard isMonitoring else { return }

        let pasteboard = NSPasteboard.general

        // Snapshot identity up front: the sensitive-type filter and the content
        // reads below must describe the same pasteboard generation. (NSPasteboard
        // is not documented thread-safe, so all reads stay on the main thread.)
        let snapshotCount = pasteboard.changeCount

        guard let types = pasteboard.types else { return }

        // Filter sensitive / transient / secret-manager content
        guard !types.contains(where: { Self.isSensitiveType($0) }) else { return }

        // Extract text content
        let text = pasteboard.string(forType: .string)

        // Extract image data, remembering which representation was read so it
        // can be written back with a truthful type declaration.
        var imageData: Data?
        var imageType: NSPasteboard.PasteboardType?
        if let png = pasteboard.data(forType: .png) {
            imageData = png
            imageType = .png
        } else if let tiff = pasteboard.data(forType: .tiff) {
            imageData = tiff
            imageType = .tiff
        }

        // Another process replaced the pasteboard between the type check and
        // the reads: the filtered types no longer describe this content, and
        // the sensitive filter could have been bypassed. Discard — the next
        // poll tick captures the new content as a fresh snapshot.
        guard pasteboard.changeCount == snapshotCount else { return }

        // Must have either text or image
        guard text != nil || imageData != nil else { return }

        // Reject content that alone exceeds the memory budget. The pasteboard
        // API offers no size query without materializing the data, so a huge
        // image still costs one transient read; this drops it before hashing
        // or storage can keep it alive longer.
        guard (text?.utf8.count ?? 0) <= memoryLimit, (imageData?.count ?? 0) <= memoryLimit else { return }

        // Hash off the main actor: pure CPU over potentially large payloads
        // would otherwise stall the UI. The serializer keeps commit order
        // aligned with capture order; the generation token drops commits from
        // a monitoring session that ended while hashing was in flight.
        let generation = monitoringGeneration
        Task.detached { [weak self, serializer = captureSerializer] in
            let hash = await serializer.computeHash(text: text, image: imageData)
            await MainActor.run { [weak self] in
                self?.commitCapture(
                    hash: hash,
                    text: text,
                    image: imageData,
                    imageType: imageType,
                    types: Set(types),
                    generation: generation
                )
            }
        }
    }

    private func commitCapture(
        hash: String,
        text: String?,
        image: Data?,
        imageType: NSPasteboard.PasteboardType?,
        types: Set<NSPasteboard.PasteboardType>,
        generation: Int
    ) {
        guard isMonitoring, monitoringGeneration == generation else { return }
        store.addOrUpdate(hash: hash, text: text, image: image, types: types, imageType: imageType)
    }

    // MARK: - Sensitive Type Filtering

    /// Pasteboard markers that clipboard-history tools agree to skip
    /// (conventions documented at https://nspasteboard.org).
    static let sensitiveTypeMarkers: Set<String> = [
        "org.nspasteboard.TransientType",
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.AutoGeneratedType",
        "de.petermaurer.TransientPasteboardType",
        "com.typeit4me.clipping",
        "Pasteboard generator type", // Typinator
        "com.apple.is-remote-clipboard",
    ]

    /// Secret-manager type prefixes (1Password marks concealed items this way).
    static let sensitiveTypePrefixes: [String] = [
        "com.agilebits.onepassword",
    ]

    /// Permissive substring fallback for app-specific variants of the convention.
    private static let sensitiveTypeSubstrings = ["TransientType", "ConcealedType", "AutoGeneratedType"]

    static func isSensitiveType(_ type: NSPasteboard.PasteboardType) -> Bool {
        let rawValue = type.rawValue
        if sensitiveTypeMarkers.contains(rawValue) { return true }
        if sensitiveTypePrefixes.contains(where: rawValue.hasPrefix) { return true }
        if sensitiveTypeSubstrings.contains(where: rawValue.contains) { return true }
        return false
    }

    // MARK: - Settings

    @Published var timeLimit: TimeInterval = 86400 {
        didSet {
            store.setTimeLimit(timeLimit)
            UserDefaults.standard.set(timeLimit, forKey: Self.timeLimitKey)
        }
    }

    @Published var memoryLimit: Int = 50 * 1024 * 1024 {
        didSet {
            store.setMemoryLimit(memoryLimit)
            UserDefaults.standard.set(memoryLimit, forKey: Self.memoryLimitKey)
        }
    }

    var memoryUsage: Int { store.memoryUsage }
    var itemCount: Int { store.itemCount }

    private static let timeLimitKey = "clipboard.retentionSeconds"
    private static let memoryLimitKey = "clipboard.memoryLimitBytes"

    private static func loadTimeLimit() -> TimeInterval {
        if let stored = UserDefaults.standard.object(forKey: timeLimitKey) as? Double, stored > 0 {
            return stored
        }
        return 86400
    }

    private static func loadMemoryLimit() -> Int {
        if let stored = UserDefaults.standard.object(forKey: memoryLimitKey) as? Int, stored > 0 {
            return stored
        }
        return 50 * 1024 * 1024
    }
}

/// Serializes content hashing off the main actor so large payloads never stall
/// the UI, while preserving capture order for commits.
private actor CaptureHashSerializer {
    func computeHash(text: String?, image: Data?) -> String {
        ClipboardItem.computeHash(text: text, image: image)
    }
}
