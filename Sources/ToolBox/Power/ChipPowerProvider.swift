import Foundation

protocol IOReportPowerSampling: AnyObject {
    func sample() throws -> IOReportPowerReading?
    func reset()
}

extension IOReportPowerSampler: IOReportPowerSampling {}

final class DarwinChipPowerProvider: ChipPowerProviding {
    private let samplerFactory: () throws -> any IOReportPowerSampling
    private let smcReader: SMCSystemPowerReader
    private let authorizedModeEnabled: () -> Bool
    private let authorizedSamplerFactory: () -> any AuthorizedPowerSampling
    private let restartAuthorizedMode: @MainActor () async -> Bool
    private let authorizedSamplingRecovered: @MainActor () -> Void
    private let authorizedRecoveryDelay: TimeInterval
    private let authorizedMaximumRecoveryDelay: TimeInterval
    private let stateLock = NSLock()
    private let smcLock = NSLock()
    private var task: Task<Void, Never>?
    private var activeAuthorizedSampler: (any AuthorizedPowerSampling)?
    private var runID: UInt64 = 0
    private var latestSnapshotValue: ChipPowerSnapshot?
    private var onUpdateValue: ((ChipPowerSnapshot) -> Void)?

    var latestSnapshot: ChipPowerSnapshot? {
        withStateLock { latestSnapshotValue }
    }

    var onUpdate: ((ChipPowerSnapshot) -> Void)? {
        get { withStateLock { onUpdateValue } }
        set { withStateLock { onUpdateValue = newValue } }
    }

    init(
        samplerFactory: @escaping () throws -> any IOReportPowerSampling = { try IOReportPowerSampler() },
        smcReader: SMCSystemPowerReader = SMCSystemPowerReader(),
        authorizedModeEnabled: @escaping () -> Bool = {
            UserDefaults.standard.bool(forKey: PowerSamplingService.enabledKey)
        },
        authorizedSamplerFactory: @escaping () -> any AuthorizedPowerSampling = { AuthorizedPowerClient() },
        // Must outlive the client's restart hold-off plus launchd's ~10s respawn
        // throttle after a failed helper spawn (e.g. a stale launch constraint
        // right after an app update); otherwise the watchdog restarts again
        // just before the self-correcting retry would succeed.
        authorizedRecoveryDelay: TimeInterval = 30,
        authorizedMaximumRecoveryDelay: TimeInterval = 300,
        restartAuthorizedMode: @escaping @MainActor () async -> Bool = {
            await AuthorizedPowerSettings.shared.restartAfterSamplingFailure()
        },
        authorizedSamplingRecovered: @escaping @MainActor () -> Void = {
            AuthorizedPowerSettings.shared.recordSamplingRecovered()
        }
    ) {
        self.samplerFactory = samplerFactory
        self.smcReader = smcReader
        self.authorizedModeEnabled = authorizedModeEnabled
        self.authorizedSamplerFactory = authorizedSamplerFactory
        self.authorizedRecoveryDelay = authorizedRecoveryDelay
        self.authorizedMaximumRecoveryDelay = authorizedMaximumRecoveryDelay
        self.restartAuthorizedMode = restartAuthorizedMode
        self.authorizedSamplingRecovered = authorizedSamplingRecovered
    }

    func start(interval: TimeInterval = 1.0) {
        stateLock.lock()
        guard task == nil else {
            stateLock.unlock()
            return
        }
        runID &+= 1
        let currentRunID = runID
        task = Task { [weak self] in
            await self?.run(id: currentRunID, interval: interval)
        }
        stateLock.unlock()
    }

    func stop() {
        stateLock.lock()
        runID &+= 1
        let runningTask = task
        let authorizedSampler = activeAuthorizedSampler
        activeAuthorizedSampler = nil
        task = nil
        stateLock.unlock()
        runningTask?.cancel()
        authorizedSampler?.stop()
    }

    func snapshot() -> ChipPowerSnapshot {
        latestSnapshot ?? ChipPowerSnapshot(
            timestamp: Date(),
            status: .unavailable,
            source: .unavailable,
            chipName: ChipIdentityProvider.chipName(),
            macModel: ChipIdentityProvider.macModel(),
            cpuWatts: nil,
            gpuWatts: nil,
            aneWatts: nil,
            combinedWatts: nil,
            systemWatts: nil,
            dramWatts: nil,
            gpuSRAMWatts: nil,
            sampleInterval: nil,
            message: "No sample has been collected yet."
        )
    }

    private func run(id: UInt64, interval: TimeInterval) async {
        let authorizedSampler = authorizedSamplerFactory()
        let accepted = withStateLock {
            guard runID == id, task != nil else { return false }
            activeAuthorizedSampler = authorizedSampler
            return true
        }
        guard accepted else { authorizedSampler.stop(); return }
        let sampler: (any IOReportPowerSampling)?
        let ioReportMessage: String?
        do {
            sampler = try samplerFactory()
            ioReportMessage = nil
        } catch {
            sampler = nil
            ioReportMessage = error.localizedDescription
        }

        let chipName = ChipIdentityProvider.chipName()
        let macModel = ChipIdentityProvider.macModel()
        var wasAuthorized = false
        // The failed-restart streak outlives this run, so report the first
        // fresh sample of each run and after each restart.
        var reportsRecovery = true
        var recovery = AuthorizedPowerRecovery(
            gracePeriod: authorizedRecoveryDelay,
            maximumDelay: authorizedMaximumRecoveryDelay,
            maximumObservationGap: max(interval * 3, authorizedRecoveryDelay)
        )
        defer {
            sampler?.reset()
            authorizedSampler.stop()
            finishRun(id: id)
        }

        while !Task.isCancelled, isCurrentRun(id) {
            let systemWatts = readSystemWatts()
            let snapshot: ChipPowerSnapshot
            let usesAuthorization = authorizedModeEnabled()
            if usesAuthorization != wasAuthorized {
                sampler?.reset()
                recovery.reset()
                wasAuthorized = usesAuthorization
            }
            if usesAuthorization {
                let response = authorizedSampler.response()
                snapshot = Self.authorizedSnapshot(
                    response: response, systemWatts: systemWatts, chipName: chipName, macModel: macModel
                )
                if reportsRecovery, response.reading?.isFresh(at: Date()) == true {
                    reportsRecovery = false
                    await authorizedSamplingRecovered()
                }
                if recovery.observe(response), await restartAuthorizedSampling(runID: id) {
                    authorizedSampler.restart()
                    recovery.markRestarted()
                    reportsRecovery = true
                }
            } else if let sampler {
                authorizedSampler.suspend()
                do {
                    let reading = try sampler.sample()
                    snapshot = makeSnapshot(
                        status: reading == nil ? .warmingUp : (reading?.invalidChannels.isEmpty == false ? .partial : .ok),
                        reading: reading,
                        source: .ioReportEnergyModel,
                        systemWatts: systemWatts,
                        chipName: chipName,
                        macModel: macModel,
                        message: reading == nil ? "Waiting for a second IOReport sample." : reading.flatMap {
                            $0.invalidChannels.isEmpty ? nil
                                : "IOReport channels are stale or invalid: \($0.invalidChannels.joined(separator: ", "))."
                        }
                    )
                } catch {
                    snapshot = makeSnapshot(
                        status: .unavailable,
                        reading: nil,
                        source: .ioReportEnergyModel,
                        systemWatts: systemWatts,
                        chipName: chipName,
                        macModel: macModel,
                        message: error.localizedDescription
                    )
                }
            } else {
                authorizedSampler.suspend()
                let hasSMC = systemWatts != nil
                let message = ioReportMessage ?? "IOReport is unavailable."
                snapshot = ChipPowerSnapshot(
                    timestamp: Date(),
                    status: hasSMC ? .partial : .unsupported,
                    source: hasSMC ? .smcSystemPower : .unavailable,
                    chipName: chipName,
                    macModel: macModel,
                    cpuWatts: nil,
                    gpuWatts: nil,
                    aneWatts: nil,
                    combinedWatts: nil,
                    systemWatts: systemWatts,
                    dramWatts: nil,
                    gpuSRAMWatts: nil,
                    sampleInterval: nil,
                    message: hasSMC
                        ? "IOReport unavailable: \(message). Using SMC system power only."
                        : message
                )
            }

            guard !Task.isCancelled, isCurrentRun(id) else { break }
            publish(snapshot, runID: id)
            do {
                let seconds = max(interval, 0.25)
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                break
            }
        }
    }

    private func publish(_ snapshot: ChipPowerSnapshot, runID: UInt64) {
        let publication: (accepted: Bool, callback: ((ChipPowerSnapshot) -> Void)?) = withStateLock {
            guard self.runID == runID, task != nil else { return (false, nil) }
            latestSnapshotValue = snapshot
            return (true, onUpdateValue)
        }
        guard publication.accepted, isCurrentRun(runID) else { return }
        publication.callback?(snapshot)
    }

    @MainActor
    private func restartAuthorizedSampling(runID: UInt64) async -> Bool {
        guard !Task.isCancelled, isCurrentRun(runID), authorizedModeEnabled() else { return false }
        return await restartAuthorizedMode()
    }

    private func isCurrentRun(_ id: UInt64) -> Bool {
        withStateLock { runID == id && task != nil }
    }

    private func finishRun(id: UInt64) {
        withStateLock {
            if runID == id {
                task = nil
                activeAuthorizedSampler = nil
            }
        }
    }

    static func authorizedSnapshot(
        response: PowerSamplingResponse,
        systemWatts: Double?, chipName: String?, macModel: String?, now: Date = Date()
    ) -> ChipPowerSnapshot {
        let reading = response.reading.flatMap { $0.isFresh(at: now) ? $0 : nil }
        let message: String?
        if reading != nil {
            message = nil
        } else if response.failure == .authorizationRequired {
            message = "Power sampling requires approval in System Settings."
        } else if response.failure != nil || response.reading != nil {
            message = "Authorized power sampling is unavailable."
        } else {
            message = "Waiting for a system power sample."
        }
        return ChipPowerSnapshot(
            timestamp: reading?.timestamp ?? now,
            status: reading != nil ? (reading?.gpuWatts == nil || reading?.aneWatts == nil
                || reading?.combinedWatts == nil ? .partial : .ok)
                : (response.failure == nil && response.reading == nil ? .warmingUp : .unavailable),
            source: .systemPowermetrics,
            chipName: chipName, macModel: macModel,
            cpuWatts: reading?.cpuWatts, gpuWatts: reading?.gpuWatts,
            aneWatts: reading?.aneWatts, combinedWatts: reading?.combinedWatts,
            systemWatts: systemWatts, dramWatts: nil, gpuSRAMWatts: nil,
            sampleInterval: reading?.interval, message: message
        )
    }

    private func readSystemWatts() -> Double? {
        smcLock.lock()
        defer { smcLock.unlock() }
        return smcReader.readSystemWatts()
    }

    @discardableResult
    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func makeSnapshot(
        status: ChipPowerStatus,
        reading: IOReportPowerReading?,
        source: ChipPowerSource,
        systemWatts: Double?,
        chipName: String?,
        macModel: String?,
        message: String?
    ) -> ChipPowerSnapshot {
        ChipPowerSnapshot(
            timestamp: Date(),
            status: status,
            source: source,
            chipName: chipName,
            macModel: macModel,
            cpuWatts: reading.flatMap {
                !$0.invalidChannels.contains(where: { $0.hasSuffix("CPU Energy") })
                    && ($0.cpuChannelCount > 0 || $0.cpuWatts != 0) ? $0.cpuWatts : nil
            },
            gpuWatts: reading.flatMap {
                !$0.invalidChannels.contains("GPU Energy")
                    && ($0.gpuChannelCount > 0 || $0.gpuWatts != 0) ? $0.gpuWatts : nil
            },
            aneWatts: reading.flatMap { reading in
                reading.invalidChannels.contains { $0.hasPrefix("ANE") } ? nil : reading.aneWatts
            },
            combinedWatts: reading.flatMap { $0.invalidChannels.isEmpty ? $0.combinedWatts : nil },
            systemWatts: systemWatts,
            dramWatts: reading.flatMap { reading in
                reading.invalidChannels.contains { $0.hasPrefix("DRAM") } ? nil : reading.dramWatts
            },
            gpuSRAMWatts: reading.flatMap { reading in
                reading.invalidChannels.contains { $0.hasPrefix("GPU SRAM") } ? nil : reading.gpuSRAMWatts
            },
            sampleInterval: reading?.sampleInterval,
            message: message
        )
    }
}

/// Restarts the helper whenever an outage outlasts the current delay, doubling
/// the delay (up to `maximumDelay`) while it stays down. Settings turn sampling
/// off after too many failed restarts in a row. A fresh sample (including zero
/// watts) starts a new healthy period.
struct AuthorizedPowerRecovery {
    let gracePeriod: TimeInterval
    let maximumDelay: TimeInterval
    let maximumObservationGap: TimeInterval
    private var unavailableSince: Date?
    private var lastObservation: Date?
    private var restarts = 0

    init(gracePeriod: TimeInterval = 10, maximumDelay: TimeInterval = 300, maximumObservationGap: TimeInterval = 10) {
        self.gracePeriod = gracePeriod
        self.maximumDelay = max(maximumDelay, gracePeriod)
        self.maximumObservationGap = maximumObservationGap
    }

    /// How long the current outage must last before the next restart.
    var currentDelay: TimeInterval {
        min(gracePeriod * pow(2, Double(min(restarts, 32))), maximumDelay)
    }

    mutating func reset() {
        unavailableSince = nil
        lastObservation = nil
        restarts = 0
    }

    mutating func markRestarted(now: Date = Date()) {
        restarts += 1
        unavailableSince = now
        lastObservation = now
    }

    /// Returns true when the helper should be restarted. It keeps returning true
    /// until `markRestarted` is called, so a deferred restart is retried.
    mutating func observe(_ response: PowerSamplingResponse, now: Date = Date()) -> Bool {
        // An approval prompt can stay open indefinitely without being a failure.
        if response.failure == .authorizationRequired || response.reading?.isFresh(at: now) == true {
            reset()
            return false
        }
        if let lastObservation,
           now.timeIntervalSince(lastObservation) < 0 || now.timeIntervalSince(lastObservation) > maximumObservationGap {
            // Do not count sleep or a paused sampling loop as continuous N/A.
            unavailableSince = nil
        }
        lastObservation = now
        guard let unavailableSince else {
            self.unavailableSince = now
            return false
        }
        return now.timeIntervalSince(unavailableSince) >= currentDelay
    }
}
