import Combine
import Foundation

struct AudioRoutingRow: Identifiable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let isRunning: Bool
    let volumePercent: Int
    let outputDeviceUID: String?
    let state: AudioRouteState

    /// HAL/recently-active or route confirmed PCM-active.
    var isCurrentlyPlaying: Bool {
        if isRunning { return true }
        if case .active = state { return true }
        return false
    }
}

private struct AudioRoutingProcessIdentity: Hashable {
    let objectID: UInt32
    let bundleID: String
}

private struct AudioRoutingRegistrySnapshot: Equatable {
    let processes: [AudioProcessSnapshot]
    let devices: [AudioOutputDevice]
    let defaultOutputUID: String?
}

private struct TerminalRouteFailure {
    let message: String
    let failedAt: Date
    let retryCount: Int
    
    func incrementingRetry(now: Date) -> TerminalRouteFailure {
        TerminalRouteFailure(
            message: message,
            failedAt: now,
            retryCount: retryCount + 1
        )
    }
}

struct PendingTaskOwnership<Key: Hashable> {
    private var nextOwner: UInt64 = 0
    private var owners: [Key: UInt64] = [:]
    private var timestamps: [Key: Date] = [:]
    private let timeout: TimeInterval
    private let nowProvider: () -> Date
    
    init(timeout: TimeInterval = 5.0, nowProvider: @escaping () -> Date = Date.init) {
        self.timeout = timeout
        self.nowProvider = nowProvider
    }

    mutating func claim(_ key: Key) -> UInt64? {
        // P2 Fix: Check for stale ownership and force-release if timed out
        if let existingOwner = owners[key],
           let timestamp = timestamps[key] {
            let now = nowProvider()
            if now.timeIntervalSince(timestamp) > timeout {
                // Ownership has expired, force release and allow new claim
                owners[key] = nil
                timestamps[key] = nil
            } else {
                // Still owned and not expired
                return nil
            }
        }
        
        guard owners[key] == nil else { return nil }
        nextOwner &+= 1
        owners[key] = nextOwner
        timestamps[key] = nowProvider()
        return nextOwner
    }

    mutating func release(_ key: Key, owner: UInt64) -> Bool {
        guard owners[key] == owner else { return false }
        owners[key] = nil
        timestamps[key] = nil
        return true
    }
    
    mutating func forceRelease(_ key: Key) {
        owners[key] = nil
        timestamps[key] = nil
    }

    mutating func removeAll() {
        owners.removeAll()
        timestamps.removeAll()
    }
}

@MainActor
final class AudioRoutingService: ObservableObject {
    @Published private(set) var rows: [AudioRoutingRow] = []
    /// Menu-bar mixer: only apps that are currently (or recently) playing.
    /// Saved-but-idle rules stay out of the compact panel and live in Settings.
    @Published private(set) var menuRows: [AudioRoutingRow] = []
    /// Settings detail list. Mirrors SoundSource favorites + active:
    /// - currently playing first
    /// - then idle apps that still have a saved rule
    @Published private(set) var playingRows: [AudioRoutingRow] = []
    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published private(set) var globalError: String?

    private let ruleStore: AudioRuleStore
    private let processRegistry: any AudioProcessRegistryProviding
    private let deviceRegistry: any AudioDeviceRegistryProviding
    private let persistenceDelay: Duration
    private var rules: [AppAudioRule] = []
    private var routeStates: [String: AudioRouteState] = [:]
    private var appliedPlans: [AudioRoutePlan] = []
    /// Presentation always uses the newest flags, even if an older reconcile finishes later.
    private var latestProcesses: [AudioProcessSnapshot] = []
    private var storeError: String?
    private var registryError: String?
    private var capabilityError: String?
    private var routeError: String?
    private var engine: (any AudioRouteEngineControlling)?
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var serviceSession: UInt64 = 0
    private var desiredGeneration: UInt64 = 0
    private var deviceConfigurationGeneration = 0
    private var shutdownTask: Task<AudioRouteStopReport, Never>?
    private var completedShutdownReport: AudioRouteStopReport?
    private var watchdogTask: Task<Void, Never>?
    private var watchdogGeneration: UInt64?
    private var watchdogCompilation: AudioRouteCompilation?
    private var watchdogProcesses: [AudioProcessSnapshot] = []
    private var watchdogDevices: [AudioOutputDevice] = []
    private var watchdogStateOverrides: [String: AudioRouteState] = [:]
    private var watchdogPollCount = 0
    private var previousDiagnostics: [String: AudioRouteDiagnosticsSnapshot] = [:]
    private var audioServerRestartSession: UInt64?
    private var suppressedRestartRegistrySnapshot: AudioRoutingRegistrySnapshot?
    private var stalledPollCounts: [String: Int] = [:]
    private var terminalRouteFailures: [String: TerminalRouteFailure] = [:]
    private var pendingRulePersistenceTask: Task<Void, Never>?
    private var pendingVolumeApplyTasks: [String: Task<Void, Never>] = [:]
    private var pendingVolumeTaskOwnership = PendingTaskOwnership<String>()
    private var deferredVolumeChanges: [String: Int] = [:]
    private var recentlyActiveExpiryTask: Task<Void, Never>?
    private var recentlyActiveExpiryDate: Date?
    /// Bundle IDs last observed as HAL-active or route-active (SoundSource recentlyActive).
    private var lastActiveAtByBundleID: [String: Date] = [:]
    private let nowProvider: () -> Date
    private let recentlyActiveWindow: TimeInterval

    convenience init() {
        self.init(
            ruleStore: AudioRuleStore(),
            processRegistry: AudioProcessRegistry(),
            deviceRegistry: AudioDeviceRegistry()
        )
    }

    init(
        ruleStore: AudioRuleStore,
        processRegistry: any AudioProcessRegistryProviding,
        deviceRegistry: any AudioDeviceRegistryProviding,
        engine: (any AudioRouteEngineControlling)? = nil,
        persistenceDelay: Duration = .milliseconds(200),
        recentlyActiveWindow: TimeInterval = AudioAppListVisibility.recentlyActiveWindow,
        now: @escaping () -> Date = Date.init
    ) {
        self.ruleStore = ruleStore
        self.processRegistry = processRegistry
        self.deviceRegistry = deviceRegistry
        self.engine = engine
        self.persistenceDelay = persistenceDelay
        self.recentlyActiveWindow = recentlyActiveWindow
        self.nowProvider = now
        // P2 Fix: Initialize PendingTaskOwnership with timeout and nowProvider
        self.pendingVolumeTaskOwnership = PendingTaskOwnership(timeout: 5.0, nowProvider: now)
    }

    func start() {
        guard !started else { return }
        completedShutdownReport = nil
        serviceSession &+= 1
        let session = serviceSession
        started = true
        if engine == nil {
            if #available(macOS 14.2, *) {
                engine = AudioRouteController(
                    nativeEngine: SwiftAudioRouteEngineAdapter(
                        runtime: AudioRouteRuntime(hal: SystemCoreAudioHAL())
                    )
                )
            } else {
                capabilityError = "分应用音频需要 macOS 14.2 或更高版本。"
            }
        }
        let result = ruleStore.load()
        rules = result.rules
        storeError = result.issue == nil ? nil : "音频规则无法读取，已暂时停用。"
        refreshGlobalError()
        deviceRegistry.rememberedUIDs = Set(rules.compactMap(\.outputDeviceUID))

        // Activity flags only affect presentation. Route plans depend on process identity,
        // so do not restart an unchanged route when `pir?` / `piro` flickers.
        processRegistry.snapshotPublisher
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] processes in
                guard let self, self.isCurrentSession(session) else { return }
                let previousProcesses = self.latestProcesses
                self.latestProcesses = processes
                self.watchdogProcesses = processes
                self.rebuildRows(processes: processes, devices: self.deviceRegistry.snapshot)
                self.recoverTerminalRouteIfNeeded(
                    previousProcesses: previousProcesses,
                    currentProcesses: processes,
                    session: session
                )
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(
            processRegistry.snapshotPublisher.removeDuplicates(by: Self.haveSameRoutingProcesses),
            deviceRegistry.snapshotPublisher.removeDuplicates(),
            deviceRegistry.defaultOutputPublisher.removeDuplicates()
        )
        .receive(on: RunLoop.main)
            .sink { [weak self] processes, devices, defaultUID in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.consumeSuppressedRestartSnapshot(
                        processes: processes,
                        devices: devices,
                        defaultOutputUID: defaultUID
                    ) {
                        return
                    }
                    await self.reconcile(
                    processes: processes,
                    devices: devices,
                    defaultOutputUID: defaultUID,
                    session: session
                )
            }
        }
        .store(in: &cancellables)

        Publishers.CombineLatest(
            processRegistry.lastErrorPublisher,
            deviceRegistry.lastErrorPublisher
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] processError, deviceError in
                guard let self, self.isCurrentSession(session) else { return }
                self.registryError = (processError ?? deviceError).map { "Core Audio：\($0)" }
                self.refreshGlobalError()
            }
            .store(in: &cancellables)

        deviceRegistry.serviceGenerationPublisher
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handleAudioServerRestart(session: session)
                }
            }
            .store(in: &cancellables)

        deviceRegistry.routeGenerationPublisher
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrentSession(session) else { return }
                    self.deviceConfigurationGeneration &+= 1
                    await self.reconcile(
                        processes: self.processRegistry.snapshot,
                        devices: self.deviceRegistry.snapshot,
                        defaultOutputUID: self.deviceRegistry.defaultOutputUID,
                        session: session
                    )
                }
            }
            .store(in: &cancellables)
        refreshGlobalError()
        deviceRegistry.start()
        processRegistry.start()
    }

    /// Synchronous stop - initiates shutdown but returns immediately without waiting.
    /// For tests or scenarios requiring full cleanup, use `stopAndWait()` instead.
    func stop() {
        flushPendingRulePersistence()
        guard started else { return }
        started = false
        serviceSession &+= 1
        desiredGeneration &+= 1
        audioServerRestartSession = nil
        suppressedRestartRegistrySnapshot = nil
        deferredVolumeChanges.removeAll()
        let engine = engine
        appliedPlans = []
        routeStates = [:]
        latestProcesses = []
        lastActiveAtByBundleID = [:]
        if !rows.isEmpty { rows = [] }
        if !menuRows.isEmpty { menuRows = [] }
        if !playingRows.isEmpty { playingRows = [] }
        cancelDiagnosticsWatchdog()
        cancelPendingVolumeApplications()
        cancelRecentlyActiveExpiry()
        processRegistry.stop()
        deviceRegistry.stop()
        cancellables.removeAll()
        if shutdownTask == nil {
            shutdownTask = Task {
                await engine?.stopAll(reason: .serviceStopped)
                    ?? AudioRouteStopReport(succeeded: true, errorMessage: nil)
            }
        }
    }
    
    /// P2 Fix: Async stop that waits for engine shutdown to complete before returning.
    /// Use this when you need to ensure clean shutdown before starting a new service.
    func stopAndWait() async {
        stop()
        if let shutdownTask {
            _ = await shutdownTask.value
            self.shutdownTask = nil
        }
    }

    func setVolume(bundleID: String, percent: Int) {
        mutateRule(bundleID: bundleID, runtimeGainPercent: percent, persistence: .debounced) {
            $0.setVolumePercent(percent)
        }
    }

    func stepVolume(bundleID: String, delta: Int) {
        let current = rules.first(where: { $0.bundleID == bundleID })?.volumePercent ?? 100
        setVolume(bundleID: bundleID, percent: current + delta)
    }

    func setOutputDevice(bundleID: String, uid: String?) {
        mutateRule(bundleID: bundleID, persistence: .immediate) { $0.outputDeviceUID = uid }
    }

    private enum RulePersistence {
        case immediate
        case debounced
    }

    private func mutateRule(
        bundleID: String,
        runtimeGainPercent: Int? = nil,
        persistence: RulePersistence,
        mutation: (inout AppAudioRule) -> Void
    ) {
        var rule = rules.first(where: { $0.bundleID == bundleID }) ?? AppAudioRule(bundleID: bundleID)
        mutation(&rule)
        rules.removeAll { $0.bundleID == bundleID }
        rules.append(rule)
        switch persistence {
        case .immediate:
            pendingRulePersistenceTask?.cancel()
            pendingRulePersistenceTask = nil
            persistRules()
        case .debounced:
            scheduleRulePersistence()
        }
        deviceRegistry.rememberedUIDs = Set(rules.compactMap(\.outputDeviceUID))
        // Keep controls responsive while the actor-backed audio engine catches up.
        rebuildRows(processes: latestProcesses, devices: deviceRegistry.snapshot)
        let session = serviceSession
        if runtimeGainPercent != nil {
            scheduleVolumeApplication(bundleID: bundleID, session: session)
        } else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.reconcile(
                    processes: self.processRegistry.snapshot,
                    devices: self.deviceRegistry.snapshot,
                    defaultOutputUID: self.deviceRegistry.defaultOutputUID,
                    session: session
                )
            }
        }
    }

    /// Throttle slider traffic without debounce starvation: apply the newest value at
    /// most once per display frame, then immediately schedule another pass if it changed.
    private func scheduleVolumeApplication(bundleID: String, session: UInt64) {
        // P1 Fix: If audio server is restarting, defer the volume change instead of silently dropping it
        guard audioServerRestartSession == nil else {
            deferredVolumeChanges[bundleID] = rules.first(where: { $0.bundleID == bundleID })?.volumePercent ?? 100
            return
        }
        guard let taskOwner = pendingVolumeTaskOwnership.claim(bundleID) else { return }
        pendingVolumeApplyTasks[bundleID] = Task { @MainActor [weak self] in
            guard let self else { return }
            var requestedPercent: Int?
            defer {
                if self.pendingVolumeTaskOwnership.release(bundleID, owner: taskOwner) {
                    self.pendingVolumeApplyTasks[bundleID] = nil
                    let latestPercent = self.rules.first(where: { $0.bundleID == bundleID })?.volumePercent
                    if self.isCurrentSession(session),
                       let requestedPercent,
                       latestPercent != requestedPercent {
                        self.scheduleVolumeApplication(bundleID: bundleID, session: session)
                    }
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.isCurrentSession(session),
                  let percent = self.rules.first(where: { $0.bundleID == bundleID })?.volumePercent else {
                return
            }
            requestedPercent = percent
            if !(await self.applyRuntimeGainIfPossible(
                bundleID: bundleID,
                percent: percent,
                session: session
            )) {
                await self.reconcile(
                    processes: self.processRegistry.snapshot,
                    devices: self.deviceRegistry.snapshot,
                    defaultOutputUID: self.deviceRegistry.defaultOutputUID,
                    session: session
                )
            }
        }
    }

    private func cancelPendingVolumeApplications() {
        pendingVolumeTaskOwnership.removeAll()
        pendingVolumeApplyTasks.values.forEach { $0.cancel() }
        pendingVolumeApplyTasks.removeAll()
    }

    private func scheduleRulePersistence() {
        pendingRulePersistenceTask?.cancel()
        let delay = persistenceDelay
        pendingRulePersistenceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            pendingRulePersistenceTask = nil
            persistRules()
        }
    }

    private func flushPendingRulePersistence() {
        guard pendingRulePersistenceTask != nil else { return }
        pendingRulePersistenceTask?.cancel()
        pendingRulePersistenceTask = nil
        persistRules()
    }

    private func persistRules() {
        do {
            try ruleStore.save(rules)
            storeError = nil
        } catch {
            storeError = "无法保存音频规则：\(error.localizedDescription)"
        }
        refreshGlobalError()
    }

    func reconcile(
        processes: [AudioProcessSnapshot],
        devices: [AudioOutputDevice],
        defaultOutputUID: String?,
        session: UInt64? = nil,
        duringAudioServerRestartSession restartSession: UInt64? = nil
    ) async {
        guard isCurrentSession(session) else { return }
        if let audioServerRestartSession,
           audioServerRestartSession != restartSession {
            return
        }
        if latestProcesses.isEmpty || !Self.haveSameRoutingProcesses(latestProcesses, processes) {
            latestProcesses = processes
        }
        desiredGeneration &+= 1
        let generation = desiredGeneration
        if self.devices != devices {
            self.devices = devices
        }
        let compilation = RoutePlanCompiler.compile(
            rules: rules,
            processes: processes,
            devices: devices,
            defaultOutputUID: defaultOutputUID,
            deviceConfigurationGeneration: deviceConfigurationGeneration
        )
        
        // P1 Fix: Clean up stale terminalRouteFailures for routes no longer in compilation
        let currentRouteIDs = Set(compilation.plans.map(\.id))
        terminalRouteFailures = terminalRouteFailures.filter { routeID, _ in
            currentRouteIDs.contains(routeID)
        }
        
        // Keep the previous stable route state while the actor applies a new plan.
        // Presentation uses the newest activity snapshot, not this reconcile's captured flags.
        rebuildRows(processes: latestProcesses, devices: devices)

        if let shutdownTask {
            let stopReport = await shutdownTask.value
            self.shutdownTask = nil
            guard isCurrentSession(session), generation == desiredGeneration else { return }
            guard stopReport.succeeded else {
                appliedPlans = []
                routeStates = failedStates(
                    resolutions: compilation.resolutions,
                    message: stopReport.errorMessage ?? "旧音频路由无法安全停止"
                )
                routeError = "音频路由停止失败：\(stopReport.errorMessage ?? "未知错误")"
                refreshGlobalError()
                rebuildRows(processes: latestProcesses, devices: devices)
                return
            }
        }

        let report: AudioRouteApplyReport
        if let engine {
            report = await engine.reconcile(plans: compilation.plans, generation: generation)
        } else if compilation.plans.isEmpty {
            report = AudioRouteApplyReport(
                generation: generation,
                status: .unchanged,
                plans: []
            )
        } else {
            report = AudioRouteApplyReport(
                generation: generation,
                status: .failed("分应用音频需要 macOS 14.2 或更高版本。"),
                plans: []
            )
        }

        guard isCurrentSession(session), report.generation == desiredGeneration else { return }
        switch report.status {
        case .applied, .unchanged:
            appliedPlans = report.plans
            routeError = nil
            if compilation.plans.isEmpty {
                cancelDiagnosticsWatchdog()
                routeStates = states(for: compilation.resolutions, routedState: .active)
            } else {
                routeStates = states(for: compilation.resolutions, routedState: .starting)
                startDiagnosticsWatchdog(
                    generation: generation,
                    compilation: compilation,
                    processes: latestProcesses,
                    devices: devices
                )
            }
        case .stale:
            return
        case let .failed(message):
            applyFailedReconcileState(
                effectivePlans: report.plans,
                requestedResolutions: compilation.resolutions,
                message: message,
                generation: generation,
                processes: latestProcesses,
                devices: devices
            )
            routeError = "音频路由启动失败：\(message)"
        case let .cleanupBlocked(message):
            applyFailedReconcileState(
                effectivePlans: report.plans,
                requestedResolutions: compilation.resolutions,
                message: message,
                generation: generation,
                processes: latestProcesses,
                devices: devices
            )
            routeError = "音频路由停止失败；已阻止重复创建 Tap：\(message)"
        }
        refreshGlobalError()
        rebuildRows(processes: latestProcesses, devices: devices)
    }

    private func rebuildRows(
        processes: [AudioProcessSnapshot],
        devices: [AudioOutputDevice]
    ) {
        let processesByBundleID = Dictionary(grouping: processes, by: \.bundleID)
        let rulesByBundleID = Dictionary(
            rules.map { ($0.bundleID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let devicesByUID = Dictionary(
            devices.map { ($0.uid, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        // Keep every resolved HAL process and saved rule internally. UI order must not
        // depend on transient activity flags, otherwise `pir?` jitter moves controls.
        let bundleIDs = Set(rulesByBundleID.keys).union(processesByBundleID.keys)
        lastActiveAtByBundleID = lastActiveAtByBundleID.filter { bundleIDs.contains($0.key) }
        let now = nowProvider()
        var nextRecentlyActiveExpiry: Date?
        let updatedRows = bundleIDs.map { bundleID in
            let matchingProcesses = processesByBundleID[bundleID, default: []]
            let process = matchingProcesses.min(by: Self.preferProcessForPresentation)
            let rule = rulesByBundleID[bundleID] ?? AppAudioRule(bundleID: bundleID)
            let hasSavedRule = rulesByBundleID[bundleID] != nil
            let selectedDeviceUnavailable = rule.outputDeviceUID.map { uid in
                devicesByUID[uid]?.isAvailable != true
            } ?? false
            let state = routeStates[bundleID]
            let isRouteActive: Bool
            if case .active = state { isRouteActive = true } else { isRouteActive = false }
            let isHALActive = matchingProcesses.contains(where: \.isHALActive)
            if isHALActive || isRouteActive {
                lastActiveAtByBundleID[bundleID] = now
            }
            let lastActiveAt = lastActiveAtByBundleID[bundleID]
            let isRecentlyActive = AudioAppListVisibility.isRecentlyActive(
                lastActiveAt: lastActiveAt,
                now: now,
                window: recentlyActiveWindow
            )
            if !isHALActive, !isRouteActive, isRecentlyActive, let lastActiveAt {
                let expiry = lastActiveAt.addingTimeInterval(recentlyActiveWindow)
                nextRecentlyActiveExpiry = min(nextRecentlyActiveExpiry ?? expiry, expiry)
            }
            let defaultState: AudioRouteState
            if selectedDeviceUnavailable {
                defaultState = .degraded("指定的输出设备不可用")
            } else if matchingProcesses.isEmpty {
                defaultState = .waitingForProcess
            } else if isHALActive {
                defaultState = .inactive
            } else if hasSavedRule, rule.volumePercent != 100 || rule.outputDeviceUID != nil {
                defaultState = .waitingForProcess
            } else {
                defaultState = .inactive
            }
            return AudioRoutingRow(
                bundleID: bundleID,
                name: process?.name ?? bundleID,
                isRunning: isHALActive || isRecentlyActive,
                volumePercent: rule.volumePercent,
                outputDeviceUID: rule.outputDeviceUID,
                state: state ?? defaultState
            )
        }.sorted(by: Self.rowsAreInStableOrder)

        if rows != updatedRows {
            rows = updatedRows
        }
        let updatedMenuRows = updatedRows
            .filter(\.isCurrentlyPlaying)
            .sorted(by: Self.rowsAreInStableOrder)
        if menuRows != updatedMenuRows {
            menuRows = updatedMenuRows
        }
        let configuredBundleIDs = Set(rulesByBundleID.keys)
        let updatedPlayingRows = updatedRows
            .filter { $0.isCurrentlyPlaying || configuredBundleIDs.contains($0.bundleID) }
            .sorted(by: Self.settingsRowsAreInOrder)
        if playingRows != updatedPlayingRows {
            playingRows = updatedPlayingRows
        }
        scheduleRecentlyActiveExpiry(at: nextRecentlyActiveExpiry, now: now)
    }

    func refreshRecentlyActiveVisibility() {
        rebuildRows(processes: latestProcesses, devices: deviceRegistry.snapshot)
    }

    private func scheduleRecentlyActiveExpiry(at date: Date?, now: Date) {
        guard date != recentlyActiveExpiryDate else { return }
        recentlyActiveExpiryTask?.cancel()
        recentlyActiveExpiryTask = nil
        recentlyActiveExpiryDate = date
        guard let date else { return }

        // Wake just after the inclusive visibility boundary to avoid a zero-delay loop.
        let delay = max(0.01, date.timeIntervalSince(now) + 0.01)
        recentlyActiveExpiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.recentlyActiveExpiryTask = nil
            self.recentlyActiveExpiryDate = nil
            self.refreshRecentlyActiveVisibility()
        }
    }

    private func cancelRecentlyActiveExpiry() {
        recentlyActiveExpiryTask?.cancel()
        recentlyActiveExpiryTask = nil
        recentlyActiveExpiryDate = nil
    }

    private static func haveSameRoutingProcesses(
        _ current: [AudioProcessSnapshot],
        _ updated: [AudioProcessSnapshot]
    ) -> Bool {
        Set(current.map { AudioRoutingProcessIdentity(objectID: $0.objectID, bundleID: $0.bundleID) })
            == Set(updated.map { AudioRoutingProcessIdentity(objectID: $0.objectID, bundleID: $0.bundleID) })
    }

    private func recoverTerminalRouteIfNeeded(
        previousProcesses: [AudioProcessSnapshot],
        currentProcesses: [AudioProcessSnapshot],
        session: UInt64
    ) {
        guard !terminalRouteFailures.isEmpty,
              Self.haveSameRoutingProcesses(previousProcesses, currentProcesses) else {
            return
        }
        let previousByIdentity = Dictionary(
            uniqueKeysWithValues: previousProcesses.map {
                (AudioRoutingProcessIdentity(objectID: $0.objectID, bundleID: $0.bundleID), $0)
            }
        )
        let newlyActiveBundleIDs = Set(currentProcesses.compactMap { process -> String? in
            let identity = AudioRoutingProcessIdentity(
                objectID: process.objectID,
                bundleID: process.bundleID
            )
            guard process.isHALActive,
                  let previous = previousByIdentity[identity],
                  previous.isRunning != process.isRunning
                    || previous.isRunningOutput != process.isRunningOutput else {
                return nil
            }
            return process.bundleID
        })
        guard !newlyActiveBundleIDs.isEmpty else { return }

        let recoveryCompilation = RoutePlanCompiler.compile(
            rules: rules.filter { newlyActiveBundleIDs.contains($0.bundleID) },
            processes: currentProcesses,
            devices: deviceRegistry.snapshot,
            defaultOutputUID: deviceRegistry.defaultOutputUID,
            deviceConfigurationGeneration: deviceConfigurationGeneration
        )
        
        // P1 Fix: Check cooldown period and retry count before attempting recovery
        let now = nowProvider()
        let shouldRecover = recoveryCompilation.plans.contains { plan in
            guard let failure = terminalRouteFailures[plan.id] else { return false }
            
            // Give up after 3 retries
            guard failure.retryCount < 3 else { return false }
            
            // Enforce 5-second cooldown between retry attempts
            let timeSinceFailure = now.timeIntervalSince(failure.failedAt)
            return timeSinceFailure >= 5.0
        }
        guard shouldRecover else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reconcile(
                processes: self.processRegistry.snapshot,
                devices: self.deviceRegistry.snapshot,
                defaultOutputUID: self.deviceRegistry.defaultOutputUID,
                session: session
            )
        }
    }

    private static func preferProcessForPresentation(
        _ lhs: AudioProcessSnapshot,
        _ rhs: AudioProcessSnapshot
    ) -> Bool {
        let lhsIsFallback = lhs.name == lhs.bundleID || lhs.name.hasPrefix("PID ")
        let rhsIsFallback = rhs.name == rhs.bundleID || rhs.name.hasPrefix("PID ")
        if lhsIsFallback != rhsIsFallback { return !lhsIsFallback }
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.objectID < rhs.objectID
    }

    private static func rowsAreInStableOrder(
        _ lhs: AudioRoutingRow,
        _ rhs: AudioRoutingRow
    ) -> Bool {
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.bundleID.localizedCaseInsensitiveCompare(rhs.bundleID) == .orderedAscending
    }

    private static func settingsRowsAreInOrder(
        _ lhs: AudioRoutingRow,
        _ rhs: AudioRoutingRow
    ) -> Bool {
        if lhs.isCurrentlyPlaying != rhs.isCurrentlyPlaying {
            return lhs.isCurrentlyPlaying && !rhs.isCurrentlyPlaying
        }
        return rowsAreInStableOrder(lhs, rhs)
    }

    private func states(
        for resolutions: [AudioRuleResolution],
        routedState: AudioRouteState
    ) -> [String: AudioRouteState] {
        Dictionary(
            resolutions.map { resolution in
                let state: AudioRouteState
                switch resolution.state {
                case let .planned(routeID):
                    state = routeID == nil ? .inactive : routedState
                case .waiting:
                    state = .waitingForProcess
                case let .degraded(reason):
                    state = .degraded(message(for: reason))
                case let .rejected(reason):
                    state = .failed(message(for: reason))
                }
                return (resolution.bundleID, state)
            },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    private func failedStates(
        resolutions: [AudioRuleResolution],
        message: String
    ) -> [String: AudioRouteState] {
        var result = states(for: resolutions, routedState: .failed(message))
        for resolution in resolutions {
            if case let .planned(routeID) = resolution.state, routeID != nil {
                result[resolution.bundleID] = .failed(message)
            }
        }
        return result
    }

    private func applyFailedReconcileState(
        effectivePlans: [AudioRoutePlan],
        requestedResolutions: [AudioRuleResolution],
        message: String,
        generation: UInt64,
        processes: [AudioProcessSnapshot],
        devices: [AudioOutputDevice]
    ) {
        appliedPlans = effectivePlans
        let requestedStates = failedStates(resolutions: requestedResolutions, message: message)
        routeStates = requestedStates
        guard !effectivePlans.isEmpty else {
            cancelDiagnosticsWatchdog()
            return
        }
        startDiagnosticsWatchdog(
            generation: generation,
            compilation: AudioRouteCompilation(
                plans: effectivePlans,
                resolutions: Self.effectiveResolutions(for: effectivePlans)
            ),
            processes: processes,
            devices: devices,
            stateOverrides: requestedStates
        )
    }

    private static func effectiveResolutions(
        for plans: [AudioRoutePlan]
    ) -> [AudioRuleResolution] {
        var seenBundleIDs = Set<String>()
        return plans.flatMap { plan in
            plan.sources.compactMap { source in
                guard seenBundleIDs.insert(source.bundleID).inserted else { return nil }
                return AudioRuleResolution(
                    bundleID: source.bundleID,
                    state: .planned(routeID: plan.id)
                )
            }
        }
    }

    private func message(for reason: AudioRouteRejectionReason) -> String {
        switch reason {
        case .missingDefaultOutputDevice:
            "系统默认输出设备不可用"
        case let .outputDeviceUnavailable(uid):
            "指定的输出设备不可用（\(uid)）"
        case let .unsupportedOutputDevice(_, reason):
            reason
        case let .sourceCapacityExceeded(limit, requested):
            "同一输出设备的音频来源过多（\(requested)/\(limit)）"
        case .excludedProcess:
            "该音频进程不允许被捕获"
        }
    }

    private func handleAudioServerRestart(session: UInt64) async {
        guard isCurrentSession(session), audioServerRestartSession == nil else { return }
        audioServerRestartSession = session
        cancelPendingVolumeApplications()
        cancelDiagnosticsWatchdog()
        desiredGeneration &+= 1
        let restartGeneration = desiredGeneration
        let report = await engine?.stopAll(reason: .audioServerRestarted)
            ?? AudioRouteStopReport(succeeded: true, errorMessage: nil)
        guard isCurrentSession(session), restartGeneration == desiredGeneration else {
            finishAudioServerRestart(session: session)
            return
        }
        guard report.succeeded else {
            appliedPlans = []
            routeError = "Core Audio 重启后旧路由无法安全释放：\(report.errorMessage ?? "未知错误")"
            refreshGlobalError()
            finishAudioServerRestart(session: session)
            return
        }
        appliedPlans = []
        processRegistry.refreshAfterAudioServerRestart()
        deviceRegistry.refreshAfterAudioServerRestart()
        await reconcile(
            processes: processRegistry.snapshot,
            devices: deviceRegistry.snapshot,
            defaultOutputUID: deviceRegistry.defaultOutputUID,
            session: session,
            duringAudioServerRestartSession: session
        )
        suppressedRestartRegistrySnapshot = AudioRoutingRegistrySnapshot(
            processes: processRegistry.snapshot,
            devices: deviceRegistry.snapshot,
            defaultOutputUID: deviceRegistry.defaultOutputUID
        )
        finishAudioServerRestart(session: session)
    }

    private func consumeSuppressedRestartSnapshot(
        processes: [AudioProcessSnapshot],
        devices: [AudioOutputDevice],
        defaultOutputUID: String?
    ) -> Bool {
        guard let suppressedRestartRegistrySnapshot else { return false }
        self.suppressedRestartRegistrySnapshot = nil
        return suppressedRestartRegistrySnapshot == AudioRoutingRegistrySnapshot(
            processes: processes,
            devices: devices,
            defaultOutputUID: defaultOutputUID
        )
    }

    private func finishAudioServerRestart(session: UInt64) {
        if audioServerRestartSession == session {
            audioServerRestartSession = nil
            
            // P1 Fix: Apply deferred volume changes that were blocked during restart
            if !deferredVolumeChanges.isEmpty {
                let deferredChanges = deferredVolumeChanges
                deferredVolumeChanges.removeAll()
                for (bundleID, percent) in deferredChanges {
                    scheduleVolumeApplication(bundleID: bundleID, session: session)
                }
            }
        }
    }

    func shutdown() async -> AudioRouteStopReport {
        if !started, let completedShutdownReport {
            return completedShutdownReport
        }
        stop()
        guard let shutdownTask else {
            return completedShutdownReport
                ?? AudioRouteStopReport(succeeded: true, errorMessage: nil)
        }
        let shutdownSession = serviceSession
        let report = await shutdownTask.value
        if !started, serviceSession == shutdownSession {
            self.shutdownTask = nil
            completedShutdownReport = report
        }
        return report
    }

    func runDiagnosticsWatchdogTick() async {
        guard started,
              let generation = watchdogGeneration,
              generation == desiredGeneration,
              let compilation = watchdogCompilation,
              !compilation.plans.isEmpty,
              let engine else {
            return
        }

        let snapshots = await engine.diagnostics()
        guard started, generation == desiredGeneration else { return }
        watchdogPollCount += 1
        let snapshotsByRouteID = Dictionary(
            snapshots
                .filter { $0.generation == generation }
                .map { ($0.routeID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        let producingOutputBundleIDs = Set(
            latestProcesses.filter(\.isRunningOutput).map(\.bundleID)
        )

        var healthByRouteID: [String: AudioRouteDiagnosticsHealth] = [:]
        for plan in compilation.plans {
            let snapshot = snapshotsByRouteID[plan.id]
            let previous = previousDiagnostics[plan.id]
            let isProducingOutput = plan.sources.contains {
                producingOutputBundleIDs.contains($0.bundleID)
            }
            // Only count polls that could indicate a broken route. A paused app stops
            // capture frames indefinitely; counting those would saturate the budget and
            // trip a false stall on the first poll after playback resumes.
            let didStall = snapshot.map { current in
                previous.map { previous in
                    // P0 Fix: Output frame stall should also check isProducingOutput to avoid
                    // false positives during route startup when buffers are still warming up.
                    if current.outputFrameCount == previous.outputFrameCount {
                        return isProducingOutput
                    }
                    return isProducingOutput
                        && current.captureFrameCount == previous.captureFrameCount
                } ?? false
            } ?? false
            stalledPollCounts[plan.id] = didStall ? (stalledPollCounts[plan.id, default: 0] + 1) : 0
            healthByRouteID[plan.id] = AudioRouteDiagnosticsEvaluator.evaluate(
                snapshot: snapshot,
                previous: previous,
                startupPollCount: watchdogPollCount,
                consecutiveStalledPollCount: stalledPollCounts[plan.id, default: 0],
                sourceIsProducingOutput: isProducingOutput
            )
        }

        let failedRouteMessages = Dictionary(
            uniqueKeysWithValues: healthByRouteID.compactMap { routeID, health in
                switch health {
                case .stalled:
                    (routeID, "音频回调已停止，路由已释放")
                case .fatal:
                    (routeID, "音频路由异常，正在重建")
                default:
                    nil
                }
            }
        )
        if !failedRouteMessages.isEmpty {
            let remainingPlans = compilation.plans.filter { failedRouteMessages[$0.id] == nil }
            let report = await engine.reconcile(plans: remainingPlans, generation: generation)
            guard generation == desiredGeneration else { return }
            switch report.status {
            case .applied, .unchanged:
                appliedPlans = report.plans
                // P1 Fix: Record failures with timestamp and retry count
                let now = nowProvider()
                for (routeID, message) in failedRouteMessages {
                    if let existing = terminalRouteFailures[routeID] {
                        terminalRouteFailures[routeID] = existing.incrementingRetry(now: now)
                    } else {
                        terminalRouteFailures[routeID] = TerminalRouteFailure(
                            message: message,
                            failedAt: now,
                            retryCount: 0
                        )
                    }
                }
                watchdogCompilation = AudioRouteCompilation(
                    plans: remainingPlans,
                    resolutions: compilation.resolutions
                )
                previousDiagnostics = previousDiagnostics.filter {
                    failedRouteMessages[$0.key] == nil
                }
                stalledPollCounts = stalledPollCounts.filter {
                    failedRouteMessages[$0.key] == nil
                }
                routeError = failedRouteMessages.values.sorted().joined(separator: "；")
                if remainingPlans.isEmpty {
                    watchdogTask?.cancel()
                    watchdogTask = nil
                    watchdogGeneration = nil
                    watchdogCompilation = nil
                }
            case .stale:
                return
            case let .failed(message), let .cleanupBlocked(message):
                let processes = watchdogProcesses
                let devices = watchdogDevices
                let stateOverrides = watchdogStateOverrides
                appliedPlans = report.plans
                cancelDiagnosticsWatchdog()
                routeStates = failedStates(resolutions: compilation.resolutions, message: message)
                routeStates.merge(stateOverrides) { _, override in override }
                routeError = "音频路由停止失败：\(message)"
                refreshGlobalError()
                rebuildRows(processes: processes, devices: devices)
                return
            }
        }

        routeStates = states(for: compilation.resolutions, routedState: .starting)
        for resolution in compilation.resolutions {
            guard case let .planned(routeID?) = resolution.state else { continue }
            if let failure = terminalRouteFailures[routeID] {
                routeStates[resolution.bundleID] = .failed(failure.message)
                continue
            }
            guard let health = healthByRouteID[routeID] else { continue }
            switch health {
            case .starting:
                routeStates[resolution.bundleID] = .starting
            case .awaitingAudio:
                routeStates[resolution.bundleID] = .awaitingAudio(
                    "权限、受保护内容或当前无可捕获音频"
                )
            case .active:
                routeStates[resolution.bundleID] = .active
            case .stalled:
                routeStates[resolution.bundleID] = .failed("音频回调已停止")
            case .fatal:
                routeStates[resolution.bundleID] = .failed("音频路由异常，正在重建")
            }
        }
        routeStates.merge(watchdogStateOverrides) { _, override in override }
        previousDiagnostics = snapshotsByRouteID.filter {
            terminalRouteFailures[$0.key] == nil
        }
        refreshGlobalError()
        rebuildRows(processes: watchdogProcesses, devices: watchdogDevices)
    }

    private func applyRuntimeGainIfPossible(
        bundleID: String,
        percent: Int,
        session: UInt64
    ) async -> Bool {
        guard isCurrentSession(session),
              let engine,
              shutdownTask == nil,
              audioServerRestartSession == nil,
              let rule = rules.first(where: { $0.bundleID == bundleID }) else {
            return false
        }
        let routeSources = appliedPlans.flatMap { plan in
            plan.sources
                .filter { $0.bundleID == bundleID }
                .map { (plan.id, $0.processObjectID) }
        }
        guard !routeSources.isEmpty else { return false }

        let selectedUID = rule.outputDeviceUID
        let routeStillRequired = percent != 100
            || (selectedUID != nil && selectedUID != deviceRegistry.defaultOutputUID)
        guard routeStillRequired else { return false }

        // A gain update belongs to the current topology generation. Advancing the
        // generation here can orphan an in-flight topology reconcile in `.starting`.
        let generation = desiredGeneration
        let parameters = routeSources.map { routeID, processObjectID in
            AudioRouteRuntimeParameters(
                generation: generation,
                routeID: routeID,
                processObjectID: processObjectID,
                targetGain: Float(percent) / 100
            )
        }
        let report = await engine.update(parameters: parameters)
        guard isCurrentSession(session), generation == desiredGeneration else { return false }
        switch report.status {
        case .applied, .unchanged:
            appliedPlans = report.plans
            if let watchdogCompilation {
                self.watchdogCompilation = AudioRouteCompilation(
                    plans: report.plans,
                    resolutions: watchdogCompilation.resolutions
                )
            }
            // P0 Fix: Reset diagnostics baseline after gain update to prevent watchdog
            // from comparing new snapshots against stale pre-update baseline.
            for plan in report.plans {
                previousDiagnostics[plan.id] = nil
                stalledPollCounts[plan.id] = 0
            }
            routeError = nil
            watchdogGeneration = generation
            refreshGlobalError()
            rebuildRows(processes: latestProcesses, devices: deviceRegistry.snapshot)
            return true
        case .stale:
            return false
        case .failed, .cleanupBlocked:
            return false
        }
    }

    private func startDiagnosticsWatchdog(
        generation: UInt64,
        compilation: AudioRouteCompilation,
        processes: [AudioProcessSnapshot],
        devices: [AudioOutputDevice],
        stateOverrides: [String: AudioRouteState] = [:]
    ) {
        cancelDiagnosticsWatchdog()
        terminalRouteFailures = [:]
        watchdogGeneration = generation
        watchdogCompilation = compilation
        watchdogProcesses = processes
        watchdogDevices = devices
        watchdogStateOverrides = stateOverrides
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.runDiagnosticsWatchdogTick()
            }
        }
    }

    private func cancelDiagnosticsWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
        watchdogGeneration = nil
        watchdogCompilation = nil
        watchdogProcesses = []
        watchdogDevices = []
        watchdogStateOverrides = [:]
        watchdogPollCount = 0
        previousDiagnostics = [:]
        stalledPollCounts = [:]
    }

    private func isCurrentSession(_ session: UInt64?) -> Bool {
        started && (session == nil || session == serviceSession)
    }

    private func refreshGlobalError() {
        let updatedError = storeError ?? registryError ?? capabilityError ?? routeError
        if globalError != updatedError {
            globalError = updatedError
        }
    }
}
