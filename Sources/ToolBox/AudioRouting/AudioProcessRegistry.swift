import AppKit
import Combine
import CoreAudio

struct HALAudioProcessRecord: Equatable, Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let name: String
    /// `kAudioProcessPropertyIsRunning` (`pir?`).
    let isRunning: Bool
    /// `kAudioProcessPropertyIsRunningOutput` (`piro`).
    let isRunningOutput: Bool

    init(
        objectID: AudioObjectID,
        pid: pid_t,
        bundleID: String,
        name: String,
        isRunningOutput: Bool,
        isRunning: Bool = false
    ) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.isRunning = isRunning
        self.isRunningOutput = isRunningOutput
    }

    var isHALActive: Bool { isRunning || isRunningOutput }
}

/// Stable application identity helpers used when projecting HAL process objects into UI rows.
enum AudioProcessIdentity {
    /// Daemon / helper noise that SoundSource keeps out of the mixer list.
    /// Exact bundle IDs or process names; keep conservative so real apps still show.
    static let ignoredBundleIDs: Set<String> = [
        "com.apple.PowerChime",
        "com.apple.controlstrip",
        "com.apple.audio.Core-Audio-Driver-Service",
        "com.apple.audio.Core-Audio-Driver-Service.helper",
        "com.apple.universalaccessd",
        "com.apple.photos.VideoConversionService",
        "com.apple.cloudpaird",
        "com.apple.cmio.ContinuityCaptureAgent",
        "com.apple.mediaremoted",
        "com.apple.VoiceOverQuickStart",
        "com.apple.audiomxd",
        "com.apple.WebKit.GPU",
        "com.apple.corespeechd",
        "com.apple.corespeechd_system",
        "com.apple.CoreSpeech",
        "com.apple.assistantd",
        "com.apple.TelephonyUtilities",
        "com.apple.avconferenced",
        "com.apple.controlcenter",
        "com.apple.Siri",
        "com.apple.SiriNCService",
        "com.apple.accessibility.heard",
        "com.youtonghy.toolbox",
        "systemsoundserverd",
        "systemstats",
        "mediaanalysisd",
        "imagent",
        "cloudpaird",
        "PerfPowerServices",
        "audioaccessoryd",
        "corespeechd",
        "loginwindow",
        "sirittsd",
        "audioanalyticsd",
        "replayd",
        "cloudphotod",
        "universalaccessd",
        "assistantd",
        "callservicesd",
        "mediaremoted",
        "AirPlayXPCHelper",
        "avconferenced",
        "streamkeeper"
    ]

    static let ignoredNameExact: Set<String> = [
        "PowerChime",
        "systemstats",
        "universalaccessd",
        "assistantd",
        "loginwindow",
        "sirittsd",
        "systemsoundserverd",
        "AirPlayXPCHelper",
        "streamkeeper"
    ]

    nonisolated static func isIgnored(bundleID: String, name: String) -> Bool {
        if !bundleID.isEmpty, ignoredBundleIDs.contains(bundleID) { return true }
        if ignoredNameExact.contains(name) { return true }
        // Core Audio driver helpers and similar always-on noise.
        if bundleID.hasPrefix("com.apple.audio.Core-Audio-Driver") { return true }
        return false
    }

    nonisolated static func resolveBundleID(
        halBundleID: String,
        pid: pid_t,
        workspaceBundleID: String?
    ) -> String {
        if !halBundleID.isEmpty { return halBundleID }
        if let workspaceBundleID, !workspaceBundleID.isEmpty { return workspaceBundleID }
        if let app = NSRunningApplication(processIdentifier: pid),
           let bid = app.bundleIdentifier,
           !bid.isEmpty {
            return bid
        }
        return ""
    }
}

private struct AudioProcessDisplayNameCacheKey: Hashable {
    let pid: pid_t
    let bundleURL: URL?
    let bundleID: String
}

final class AudioProcessDisplayNameCache {
    typealias BundleNameLoader = (URL) -> String?

    private let bundleNameLoader: BundleNameLoader
    private var names: [AudioProcessDisplayNameCacheKey: String] = [:]

    convenience init() {
        self.init(bundleNameLoader: AudioProcessDisplayNameCache.loadBundleName)
    }

    init(bundleNameLoader: @escaping BundleNameLoader) {
        self.bundleNameLoader = bundleNameLoader
    }

    func preferredDisplayName(
        pid: pid_t,
        bundleURL: URL?,
        bundleID: String,
        workspaceName: String?
    ) -> String {
        let key = AudioProcessDisplayNameCacheKey(
            pid: pid,
            bundleURL: bundleURL,
            bundleID: bundleID
        )
        if let cached = names[key] { return cached }

        let name = bundleURL.flatMap(bundleNameLoader)
            ?? workspaceName.flatMap { $0.isEmpty ? nil : $0 }
            ?? (bundleID.isEmpty ? nil : bundleID)
            ?? "PID \(pid)"
        names[key] = name
        return name
    }

    func removeAll() {
        names.removeAll()
    }

    private static func loadBundleName(url: URL) -> String? {
        guard let bundle = Bundle(url: url) else { return nil }
        if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            return displayName
        }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.isEmpty,
           name.caseInsensitiveCompare("discover") != .orderedSame {
            return name
        }
        return nil
    }
}

private struct AudioProcessActivityListenerKey: Hashable {
    let objectID: AudioObjectID
    let selector: AudioObjectPropertySelector
}

@MainActor
final class AudioProcessRegistry: ObservableObject {
    nonisolated static let processListSettleDelay: Duration = .seconds(5)

    @Published private(set) var snapshot: [AudioProcessSnapshot] = []
    @Published private(set) var lastError: String?

    private var listListener: AudioObjectPropertyListenerBlock?
    private var activityListeners: [AudioProcessActivityListenerKey: AudioObjectPropertyListenerBlock] = [:]
    private var listAddress = CoreAudioPropertyReader.address(kAudioHardwarePropertyProcessObjectList)
    // HAL publishes process-list changes before new clients always finish registering.
    // Avoid synchronous enumeration while WebKit GPU/audio clients are still initializing.
    private let reloadCoalescer = AudioRegistryEventCoalescer(
        delay: AudioProcessRegistry.processListSettleDelay
    )
    private let displayNameCache = AudioProcessDisplayNameCache()
    private var partialReloadRetryCount = 0
    private var started = false

    nonisolated static func project(records: [HALAudioProcessRecord]) -> [AudioProcessSnapshot] {
        records.compactMap { record in
            guard !record.bundleID.isEmpty else { return nil }
            guard !AudioProcessIdentity.isIgnored(bundleID: record.bundleID, name: record.name) else {
                return nil
            }
            return AudioProcessSnapshot(
                objectID: record.objectID,
                pid: record.pid,
                bundleID: record.bundleID,
                name: record.name,
                isRunningOutput: record.isRunningOutput,
                isRunning: record.isRunning
            )
        }.sorted(by: stableSnapshotOrder)
    }

    nonisolated static func updatingActivity(
        in snapshots: [AudioProcessSnapshot],
        objectID: AudioObjectID,
        isRunning: Bool,
        isRunningOutput: Bool
    ) -> [AudioProcessSnapshot]? {
        guard let index = snapshots.firstIndex(where: { $0.objectID == objectID }) else { return nil }
        let current = snapshots[index]
        guard current.isRunning != isRunning || current.isRunningOutput != isRunningOutput else {
            return snapshots
        }
        var updated = snapshots
        updated[index] = AudioProcessSnapshot(
            objectID: current.objectID,
            pid: current.pid,
            bundleID: current.bundleID,
            name: current.name,
            isRunningOutput: isRunningOutput,
            isRunning: isRunning
        )
        return updated.sorted(by: stableSnapshotOrder)
    }

    private nonisolated static func stableSnapshotOrder(
        _ lhs: AudioProcessSnapshot,
        _ rhs: AudioProcessSnapshot
    ) -> Bool {
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        let bundleOrder = lhs.bundleID.localizedCaseInsensitiveCompare(rhs.bundleID)
        if bundleOrder != .orderedSame { return bundleOrder == .orderedAscending }
        return lhs.objectID < rhs.objectID
    }

    func start() {
        guard !started else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.scheduleReload(resetRetryBudget: true) }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, .main, listener
        )
        guard status == noErr else {
            lastError = CoreAudioPropertyError.status(status, listAddress.mSelector).localizedDescription
            return
        }
        listListener = listener
        started = true
        reload()
    }

    func stop() {
        started = false
        if let listListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &listAddress, .main, listListener
            )
        }
        reloadCoalescer.cancel()
        listListener = nil
        removeActivityListeners()
        partialReloadRetryCount = 0
        displayNameCache.removeAll()
        if !snapshot.isEmpty { snapshot = [] }
    }

    func reload() {
        guard started else { return }
        do {
            let ids = try CoreAudioPropertyReader.objectIDs(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyProcessObjectList
            )
            struct WorkspaceApp {
                let name: String
                let bundleID: String
                let bundleURL: URL?
            }
            let applications = Dictionary(
                NSWorkspace.shared.runningApplications.map { app -> (pid_t, WorkspaceApp) in
                    (
                        app.processIdentifier,
                        WorkspaceApp(
                            name: app.localizedName ?? "",
                            bundleID: app.bundleIdentifier ?? "",
                            bundleURL: app.bundleURL
                        )
                    )
                },
                uniquingKeysWith: { current, _ in current }
            )
            let result = CoreAudioPropertyReader.readAvailableObjects(ids) { id in
                let pid: pid_t = try CoreAudioPropertyReader.value(
                    objectID: id, selector: kAudioProcessPropertyPID, initial: 0
                )
                // SoundSource primarily uses `pir?` (IsRunning); also read `piro` (IsRunningOutput).
                let running: UInt32 = (try? CoreAudioPropertyReader.value(
                    objectID: id, selector: kAudioProcessPropertyIsRunning, initial: UInt32(0)
                )) ?? 0
                let runningOutput: UInt32 = (try? CoreAudioPropertyReader.value(
                    objectID: id, selector: kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)
                )) ?? 0
                let halBundleID = (try? CoreAudioPropertyReader.string(
                    objectID: id, selector: kAudioProcessPropertyBundleID
                )) ?? ""
                let workspace = applications[pid]
                let bundleID = AudioProcessIdentity.resolveBundleID(
                    halBundleID: halBundleID,
                    pid: pid,
                    workspaceBundleID: workspace?.bundleID
                )
                let name = displayNameCache.preferredDisplayName(
                    pid: pid,
                    bundleURL: workspace?.bundleURL,
                    bundleID: bundleID,
                    workspaceName: workspace?.name
                )
                return HALAudioProcessRecord(
                    objectID: id,
                    pid: pid,
                    bundleID: bundleID,
                    name: name,
                    isRunningOutput: runningOutput != 0,
                    isRunning: running != 0
                )
            }
            let records = result.objects.map(\.value)
            let updatedSnapshot = Self.project(records: records)
            if snapshot != updatedSnapshot {
                snapshot = updatedSnapshot
            }
            // Ignored/unresolved HAL objects are intentionally not monitored; their
            // always-on activity must not trigger full process-list reloads.
            synchronizeActivityListeners(ids: updatedSnapshot.map(\.objectID))
            if result.failureCount == 0 {
                partialReloadRetryCount = 0
                lastError = nil
            } else {
                lastError = "\(result.failureCount) 个音频进程在刷新时已失效，已跳过。"
                schedulePartialReloadRetry()
            }
        } catch {
            lastError = error.localizedDescription
            schedulePartialReloadRetry()
        }
    }

    private func synchronizeActivityListeners(ids: [AudioObjectID]) {
        let selectors: [AudioObjectPropertySelector] = [
            kAudioProcessPropertyIsRunning,
            kAudioProcessPropertyIsRunningOutput
        ]
        let desiredKeys = Set(ids.flatMap { objectID in
            selectors.map { AudioProcessActivityListenerKey(objectID: objectID, selector: $0) }
        })

        for key in Array(activityListeners.keys) where !desiredKeys.contains(key) {
            guard let listener = activityListeners.removeValue(forKey: key) else { continue }
            var address = CoreAudioPropertyReader.address(key.selector)
            AudioObjectRemovePropertyListenerBlock(key.objectID, &address, .main, listener)
        }

        for key in desiredKeys where activityListeners[key] == nil {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.refreshActivity(objectID: key.objectID) }
            }
            var address = CoreAudioPropertyReader.address(key.selector)
            guard AudioObjectHasProperty(key.objectID, &address) else { continue }
            if AudioObjectAddPropertyListenerBlock(key.objectID, &address, .main, listener) == noErr {
                activityListeners[key] = listener
            }
        }
    }

    private func removeActivityListeners() {
        for (key, listener) in activityListeners {
            var address = CoreAudioPropertyReader.address(key.selector)
            AudioObjectRemovePropertyListenerBlock(key.objectID, &address, .main, listener)
        }
        activityListeners.removeAll()
    }

    private func refreshActivity(objectID: AudioObjectID) {
        guard started,
              let current = snapshot.first(where: { $0.objectID == objectID }) else {
            return
        }
        let runningValue: UInt32? = try? CoreAudioPropertyReader.value(
            objectID: objectID,
            selector: kAudioProcessPropertyIsRunning,
            initial: UInt32(0)
        )
        let runningOutputValue: UInt32? = try? CoreAudioPropertyReader.value(
            objectID: objectID,
            selector: kAudioProcessPropertyIsRunningOutput,
            initial: UInt32(0)
        )
        guard runningValue != nil || runningOutputValue != nil else {
            scheduleReload(resetRetryBudget: true)
            return
        }
        let updated = Self.updatingActivity(
            in: snapshot,
            objectID: objectID,
            isRunning: runningValue.map { $0 != 0 } ?? current.isRunning,
            isRunningOutput: runningOutputValue.map { $0 != 0 } ?? current.isRunningOutput
        )
        if let updated, updated != snapshot {
            snapshot = updated
        }
    }

    private func scheduleReload(resetRetryBudget: Bool = false) {
        guard started else { return }
        if resetRetryBudget { partialReloadRetryCount = 0 }
        reloadCoalescer.schedule { [weak self] in
            self?.reload()
        }
    }

    private func schedulePartialReloadRetry() {
        guard partialReloadRetryCount < 3 else { return }
        partialReloadRetryCount += 1
        scheduleReload(resetRetryBudget: false)
    }
}
