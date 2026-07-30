import AppKit
import Combine
import CoreGraphics
import Foundation
import OSLog

private final class DisplayControlReconfigurationContext {
    private let lock = NSLock()
    private weak var service: DisplayControlService?
    private var sessionID: UInt64?

    init(service: DisplayControlService) {
        self.service = service
    }

    func activate(sessionID: UInt64) {
        lock.lock()
        self.sessionID = sessionID
        lock.unlock()
    }

    func deactivate() {
        lock.lock()
        sessionID = nil
        lock.unlock()
    }

    // CoreGraphics can call from outside MainActor, so preserve the session at ingress.
    func dispatchReconfiguration() {
        lock.lock()
        let activeService = service
        let activeSessionID = sessionID
        lock.unlock()
        guard let activeService, let activeSessionID else { return }

        Task { @MainActor [weak activeService] in
            activeService?.handleDisplayReconfiguration(sessionID: activeSessionID)
        }
    }
}

private let displayControlReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, _, userInfo in
    guard let userInfo else { return }
    let context = Unmanaged<DisplayControlReconfigurationContext>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    context.dispatchReconfiguration()
}

protocol DisplayControlLifecycleSleeper: Sendable {
    func sleep(nanoseconds: UInt64) async throws
}

struct TaskDisplayControlLifecycleSleeper: DisplayControlLifecycleSleeper {
    func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

struct DisplayControlTiming: Sendable {
    var brightnessFrameDelayNanos: UInt64
    var refreshDebounceNanos: UInt64
    var reconfigurationRefreshDelayNanos: UInt64
    var wakeRefreshDelayNanos: UInt64

    static let live = DisplayControlTiming(
        brightnessFrameDelayNanos: 20_000_000,
        refreshDebounceNanos: 250_000_000,
        reconfigurationRefreshDelayNanos: 1_000_000_000,
        wakeRefreshDelayNanos: 3_000_000_000
    )
    static let immediateForTests = DisplayControlTiming(
        brightnessFrameDelayNanos: 0,
        refreshDebounceNanos: 0,
        reconfigurationRefreshDelayNanos: 0,
        wakeRefreshDelayNanos: 0
    )
}

private struct ControlWriteKey: Hashable {
    var displayID: CGDirectDisplayID
    var kind: DisplayControlKind
}

enum DisplayBrightnessWritePolicy: Equatable, Sendable {
    case manual
    case scheduled
}

private struct BrightnessWriteRequest: Equatable {
    var target: Double
    var smooth: Bool
    var force: Bool
    var policy: DisplayBrightnessWritePolicy
}

@MainActor
final class DisplayControlService: ObservableObject {
    static let shared = DisplayControlService()

    @Published private(set) var snapshot = DisplayControlSnapshot(timestamp: Date(), displays: [])
    @Published private(set) var colorPresetErrors: [CGDirectDisplayID: String] = [:]

    private let provider: DisplayControlProviding
    private let timing: DisplayControlTiming
    private let observesSystemEvents: Bool
    private let lifecycleSleeper: any DisplayControlLifecycleSleeper
    private let logger = Logger(subsystem: "ToolBox", category: "DisplayControl")
    private lazy var displayReconfigurationContext = DisplayControlReconfigurationContext(service: self)

    private var refreshTask: Task<Void, Never>?
    private var refreshAfterWritesTask: Task<Void, Never>?
    private var refreshAfterWritesID: UUID?
    private var lifecycleRefreshTask: Task<Void, Never>?
    private var lifecycleRefreshID: UUID?

    private var desiredValues: [ControlWriteKey: Double] = [:]
    private var lastSuccessfulValues: [ControlWriteKey: Double] = [:]
    private var userTargetKeys = Set<ControlWriteKey>()

    private var latestBrightnessRequests: [CGDirectDisplayID: BrightnessWriteRequest] = [:]
    private var brightnessWorkers: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var brightnessWorkerIDs: [CGDirectDisplayID: UUID] = [:]
    private let manualBrightnessWriteSubject = PassthroughSubject<
        (displayID: CGDirectDisplayID, normalizedValue: Double),
        Never
    >()

    private var pendingControlTargets: [ControlWriteKey: Double] = [:]
    private var controlWorkers: [ControlWriteKey: Task<Void, Never>] = [:]
    private var controlWorkerIDs: [ControlWriteKey: UUID] = [:]

    private var pendingVolumeTargets: [CGDirectDisplayID: Double] = [:]
    private var volumeWorkers: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var volumeWorkerIDs: [CGDirectDisplayID: UUID] = [:]

    private var pendingPresetTargets: [CGDirectDisplayID: UInt8] = [:]
    private var presetWorkers: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var presetWorkerIDs: [CGDirectDisplayID: UUID] = [:]
    private var desiredPresetValues: [CGDirectDisplayID: UInt8] = [:]
    private var lastVerifiedPresetValues: [CGDirectDisplayID: UInt8] = [:]

    private var displayCallbackRegistered = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var started = false
    private var sessionID: UInt64 = 0
    private var isSuspended = false
    private var isWakeSettling = false

    init(
        provider: DisplayControlProviding = DarwinDisplayControlProvider(),
        timing: DisplayControlTiming = .live,
        observesSystemEvents: Bool = true,
        lifecycleSleeper: any DisplayControlLifecycleSleeper = TaskDisplayControlLifecycleSleeper()
    ) {
        self.provider = provider
        self.timing = timing
        self.observesSystemEvents = observesSystemEvents
        self.lifecycleSleeper = lifecycleSleeper
    }

    func start() {
        guard !started else { return }
        started = true
        sessionID &+= 1
        isSuspended = false
        isWakeSettling = false
        if observesSystemEvents {
            registerDisplayReconfigurationCallback()
            registerWorkspaceObservers(sessionID: sessionID)
        }
        refresh()
    }

    /// Test seam: publish a snapshot without going through the provider.
    func setSnapshotForTesting(_ snapshot: DisplayControlSnapshot) {
        self.snapshot = snapshot
        seedValues(from: snapshot)
    }

    func stop() {
        started = false
        sessionID &+= 1
        isSuspended = false
        isWakeSettling = false
        cancelLifecycleRefresh()
        refreshTask?.cancel()
        refreshTask = nil
        cancelPendingWrites()
        unregisterDisplayReconfigurationCallback()
        unregisterWorkspaceObservers()
    }

    func refresh() {
        guard !isSuspended else { return }

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let next = try await provider.snapshot()
                try Task.checkCancellation()
                snapshot = next
                seedValues(from: next)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Display control refresh failed: \(error.localizedDescription, privacy: .public)")
                snapshot = DisplayControlSnapshot(timestamp: Date(), displays: [])
            }
        }
    }

    func readValue(
        displayID: CGDirectDisplayID,
        kind: DisplayControlKind
    ) async throws -> DisplayControlValue {
        try await provider.readValue(displayID: displayID, kind: kind)
    }

    var manualBrightnessWrites: AnyPublisher<
        (displayID: CGDirectDisplayID, normalizedValue: Double),
        Never
    > {
        manualBrightnessWriteSubject.eraseToAnyPublisher()
    }

    @discardableResult
    func writeValue(
        displayID: CGDirectDisplayID,
        kind: DisplayControlKind,
        normalizedValue: Double,
        options: DisplayControlWriteOptions = .none
    ) async throws -> DisplayControlValue {
        try await provider.writeValue(
            displayID: displayID,
            kind: kind,
            normalizedValue: normalizedValue,
            options: options
        )
    }

    func presentedValue(displayID: CGDirectDisplayID, kind: DisplayControlKind) -> Double? {
        desiredValues[ControlWriteKey(displayID: displayID, kind: kind)]
    }

    func presentedColorPreset(displayID: CGDirectDisplayID) -> UInt8? {
        desiredPresetValues[displayID]
    }

    func colorPresetError(displayID: CGDirectDisplayID) -> String? {
        colorPresetErrors[displayID]
    }

    func normalizedStep(displayID: CGDirectDisplayID, kind: DisplayControlKind) -> Double {
        let value = snapshot.displays
            .first(where: { $0.id == displayID })?
            .controls.first(where: { $0.kind == kind })?
            .value
        return Self.normalizedStep(for: value)
    }

    func quantizedValue(
        displayID: CGDirectDisplayID,
        kind: DisplayControlKind,
        normalizedValue: Double
    ) -> Double {
        let step = normalizedStep(displayID: displayID, kind: kind)
        let value = Self.clamp(normalizedValue)
        return Self.clamp((value / step).rounded() * step)
    }

    func writeBrightness(
        displayID: CGDirectDisplayID,
        normalizedValue: Double,
        smooth: Bool = true,
        policy: DisplayBrightnessWritePolicy = .manual
    ) {
        guard !isSuspended else { return }
        let key = ControlWriteKey(displayID: displayID, kind: .brightness)
        let target = quantizedValue(
            displayID: displayID,
            kind: .brightness,
            normalizedValue: normalizedValue
        )
        desiredValues[key] = target
        userTargetKeys.insert(key)

        let force = policy == .scheduled
        latestBrightnessRequests[displayID] = BrightnessWriteRequest(
            target: target,
            smooth: smooth,
            force: force,
            policy: policy
        )

        if policy == .manual {
            manualBrightnessWriteSubject.send((displayID, target))
        }

        guard brightnessWorkers[displayID] == nil else { return }

        let workerID = UUID()
        brightnessWorkerIDs[displayID] = workerID
        brightnessWorkers[displayID] = Task { [weak self] in
            await self?.runBrightnessWorker(
                displayID: displayID,
                workerID: workerID
            )
        }
    }

    func writeControl(
        displayID: CGDirectDisplayID,
        kind: DisplayControlKind,
        normalizedValue: Double
    ) {
        if kind == .brightness {
            writeBrightness(displayID: displayID, normalizedValue: normalizedValue)
            return
        }
        if kind == .volume {
            setVolume(displayID: displayID, normalizedValue: normalizedValue)
            return
        }
        enqueueControlWrite(
            displayID: displayID,
            kind: kind,
            normalizedValue: normalizedValue
        )
    }

    func setVolume(displayID: CGDirectDisplayID, normalizedValue: Double) {
        guard !isSuspended else { return }
        let volumeKey = ControlWriteKey(displayID: displayID, kind: .volume)
        let muteKey = ControlWriteKey(displayID: displayID, kind: .mute)
        let target = quantizedValue(
            displayID: displayID,
            kind: .volume,
            normalizedValue: normalizedValue
        )
        desiredValues[volumeKey] = target
        desiredValues[muteKey] = target <= 0 ? 1 : 0
        userTargetKeys.insert(volumeKey)
        userTargetKeys.insert(muteKey)
        pendingVolumeTargets[displayID] = target
        guard volumeWorkers[displayID] == nil else { return }

        let workerID = UUID()
        volumeWorkerIDs[displayID] = workerID
        volumeWorkers[displayID] = Task { [weak self] in
            await self?.runVolumeWorker(displayID: displayID, workerID: workerID)
        }
    }

    func setColorPreset(displayID: CGDirectDisplayID, rawValue: UInt8) {
        guard !isSuspended else { return }
        desiredPresetValues[displayID] = rawValue
        colorPresetErrors[displayID] = nil
        pendingPresetTargets[displayID] = rawValue
        guard presetWorkers[displayID] == nil else { return }

        let workerID = UUID()
        presetWorkerIDs[displayID] = workerID
        presetWorkers[displayID] = Task { [weak self] in
            await self?.runPresetWorker(displayID: displayID, workerID: workerID)
        }
    }

    func stepValue(displayID: CGDirectDisplayID, kind: DisplayControlKind, delta: Double) {
        let key = ControlWriteKey(displayID: displayID, kind: kind)
        let baseline = desiredValues[key] ?? snapshotValue(displayID: displayID, kind: kind) ?? 0
        let next = Self.clamp(baseline + delta)
        if kind == .brightness {
            writeBrightness(displayID: displayID, normalizedValue: next)
        } else if kind == .volume {
            setVolume(displayID: displayID, normalizedValue: next)
        } else {
            writeControl(displayID: displayID, kind: kind, normalizedValue: next)
        }
    }

    func setMuted(displayID: CGDirectDisplayID, muted: Bool) {
        writeControl(displayID: displayID, kind: .mute, normalizedValue: muted ? 1 : 0)
    }

    func toggleMute(displayID: CGDirectDisplayID) {
        let key = ControlWriteKey(displayID: displayID, kind: .mute)
        let current = desiredValues[key] ?? snapshotValue(displayID: displayID, kind: .mute) ?? 0
        writeControl(
            displayID: displayID,
            kind: .mute,
            normalizedValue: current >= 0.5 ? 0 : 1
        )
    }

    private func enqueueControlWrite(
        displayID: CGDirectDisplayID,
        kind: DisplayControlKind,
        normalizedValue: Double
    ) {
        guard !isSuspended else { return }
        let key = ControlWriteKey(displayID: displayID, kind: kind)
        let target = quantizedValue(
            displayID: displayID,
            kind: kind,
            normalizedValue: normalizedValue
        )
        desiredValues[key] = target
        userTargetKeys.insert(key)
        pendingControlTargets[key] = target
        guard controlWorkers[key] == nil else { return }

        let workerID = UUID()
        controlWorkerIDs[key] = workerID
        controlWorkers[key] = Task { [weak self] in
            await self?.runControlWorker(key: key, workerID: workerID)
        }
    }

    private func runBrightnessWorker(
        displayID: CGDirectDisplayID,
        workerID: UUID
    ) async {
        let key = ControlWriteKey(displayID: displayID, kind: .brightness)
        var transient = lastSuccessfulValues[key] ?? trustedSnapshotValue(
            displayID: displayID,
            kind: .brightness
        )

        do {
            while let request = latestBrightnessRequests[displayID] {
                try Task.checkCancellation()
                let target = request.target
                let next: Double
                if !request.smooth || transient == nil {
                    next = target
                } else if abs(target - transient!) < 0.01 {
                    next = target
                } else {
                    let distance = target - transient!
                    let step = distance > 0
                        ? max(distance / 6, 0.01)
                        : min(distance / 6, -0.01)
                    next = Self.clamp(transient! + step)
                }

                let options: DisplayControlWriteOptions = request.force ? .force : .none
                let value = try await provider.writeValue(
                    displayID: displayID,
                    kind: .brightness,
                    normalizedValue: next,
                    options: options
                )
                try Task.checkCancellation()
                transient = value.normalized
                lastSuccessfulValues[key] = value.normalized

                if let latest = latestBrightnessRequests[displayID],
                   abs(latest.target - value.normalized) < 0.0001 {
                    latestBrightnessRequests[displayID] = nil
                    break
                }
                if timing.brightnessFrameDelayNanos > 0 {
                    try await Task.sleep(nanoseconds: timing.brightnessFrameDelayNanos)
                } else {
                    await Task.yield()
                }
            }
            finishBrightnessWorker(displayID: displayID, workerID: workerID)
        } catch is CancellationError {
            finishBrightnessWorker(displayID: displayID, workerID: workerID)
        } catch {
            logger.error("Brightness write failed: \(error.localizedDescription, privacy: .public)")
            latestBrightnessRequests[displayID] = nil
            restoreDesiredValue(for: key)
            finishBrightnessWorker(displayID: displayID, workerID: workerID)
        }
    }

    private func finishBrightnessWorker(displayID: CGDirectDisplayID, workerID: UUID) {
        guard brightnessWorkerIDs[displayID] == workerID else { return }
        brightnessWorkers[displayID] = nil
        brightnessWorkerIDs[displayID] = nil
        scheduleRefreshWhenIdle()
    }

    private func runControlWorker(key: ControlWriteKey, workerID: UUID) async {
        do {
            while let target = pendingControlTargets.removeValue(forKey: key) {
                try Task.checkCancellation()
                let value = try await provider.writeValue(
                    displayID: key.displayID,
                    kind: key.kind,
                    normalizedValue: target
                )
                try Task.checkCancellation()
                lastSuccessfulValues[key] = value.normalized
            }
            finishControlWorker(key: key, workerID: workerID)
        } catch is CancellationError {
            finishControlWorker(key: key, workerID: workerID)
        } catch {
            logger.error("Display control write failed: \(error.localizedDescription, privacy: .public)")
            pendingControlTargets[key] = nil
            restoreDesiredValue(for: key)
            finishControlWorker(key: key, workerID: workerID)
        }
    }

    private func finishControlWorker(key: ControlWriteKey, workerID: UUID) {
        guard controlWorkerIDs[key] == workerID else { return }
        controlWorkers[key] = nil
        controlWorkerIDs[key] = nil
        scheduleRefreshWhenIdle()
    }

    private func runVolumeWorker(displayID: CGDirectDisplayID, workerID: UUID) async {
        let volumeKey = ControlWriteKey(displayID: displayID, kind: .volume)
        let muteKey = ControlWriteKey(displayID: displayID, kind: .mute)
        do {
            while let target = pendingVolumeTargets.removeValue(forKey: displayID) {
                try Task.checkCancellation()
                if target <= 0 {
                    let volume = try await provider.writeValue(
                        displayID: displayID,
                        kind: .volume,
                        normalizedValue: 0
                    )
                    let mute = try await provider.writeValue(
                        displayID: displayID,
                        kind: .mute,
                        normalizedValue: 1
                    )
                    lastSuccessfulValues[volumeKey] = volume.normalized
                    lastSuccessfulValues[muteKey] = mute.normalized
                } else {
                    let mute = try await provider.writeValue(
                        displayID: displayID,
                        kind: .mute,
                        normalizedValue: 0
                    )
                    let volume = try await provider.writeValue(
                        displayID: displayID,
                        kind: .volume,
                        normalizedValue: target
                    )
                    lastSuccessfulValues[muteKey] = mute.normalized
                    lastSuccessfulValues[volumeKey] = volume.normalized
                }
                try Task.checkCancellation()
            }
            finishVolumeWorker(displayID: displayID, workerID: workerID)
        } catch is CancellationError {
            finishVolumeWorker(displayID: displayID, workerID: workerID)
        } catch {
            logger.error("Volume write failed: \(error.localizedDescription, privacy: .public)")
            pendingVolumeTargets[displayID] = nil
            restoreDesiredValue(for: volumeKey)
            restoreDesiredValue(for: muteKey)
            finishVolumeWorker(displayID: displayID, workerID: workerID)
        }
    }

    private func finishVolumeWorker(displayID: CGDirectDisplayID, workerID: UUID) {
        guard volumeWorkerIDs[displayID] == workerID else { return }
        volumeWorkers[displayID] = nil
        volumeWorkerIDs[displayID] = nil
        scheduleRefreshWhenIdle()
    }

    private func runPresetWorker(displayID: CGDirectDisplayID, workerID: UUID) async {
        do {
            while let target = pendingPresetTargets.removeValue(forKey: displayID) {
                try Task.checkCancellation()
                let result = try await provider.writeColorPreset(
                    displayID: displayID,
                    rawValue: target
                )
                try Task.checkCancellation()
                guard presetWorkerIDs[displayID] == workerID else { return }
                lastVerifiedPresetValues[displayID] = result.verifiedRawValue
                if pendingPresetTargets[displayID] == nil {
                    desiredPresetValues[displayID] = result.verifiedRawValue
                }
                colorPresetErrors[displayID] = nil
            }
            finishPresetWorker(displayID: displayID, workerID: workerID)
        } catch is CancellationError {
            finishPresetWorker(displayID: displayID, workerID: workerID)
        } catch {
            guard presetWorkerIDs[displayID] == workerID else { return }
            logger.error("Color preset write failed: \(error.localizedDescription, privacy: .public)")
            pendingPresetTargets[displayID] = nil
            desiredPresetValues[displayID] = lastVerifiedPresetValues[displayID]
            colorPresetErrors[displayID] = error.localizedDescription
            finishPresetWorker(displayID: displayID, workerID: workerID)
        }
    }

    private func finishPresetWorker(displayID: CGDirectDisplayID, workerID: UUID) {
        guard presetWorkerIDs[displayID] == workerID else { return }
        presetWorkers[displayID] = nil
        presetWorkerIDs[displayID] = nil
        scheduleRefreshWhenIdle()
    }

    private func scheduleRefreshWhenIdle() {
        guard brightnessWorkers.isEmpty,
              controlWorkers.isEmpty,
              volumeWorkers.isEmpty,
              presetWorkers.isEmpty else {
            return
        }
        refreshAfterWritesTask?.cancel()
        let taskID = UUID()
        refreshAfterWritesID = taskID
        refreshAfterWritesTask = Task { [weak self] in
            guard let self else { return }
            do {
                if timing.refreshDebounceNanos > 0 {
                    try await Task.sleep(nanoseconds: timing.refreshDebounceNanos)
                } else {
                    await Task.yield()
                }
                try Task.checkCancellation()
                guard refreshAfterWritesID == taskID else { return }
                refreshAfterWritesTask = nil
                refreshAfterWritesID = nil
                refresh()
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func seedValues(from snapshot: DisplayControlSnapshot) {
        let displayedIDs = Set(snapshot.displays.map(\.id))
        let knownPresetIDs = Set(presetWorkers.keys)
            .union(pendingPresetTargets.keys)
            .union(desiredPresetValues.keys)
            .union(lastVerifiedPresetValues.keys)
            .union(colorPresetErrors.keys)
        for displayID in knownPresetIDs.subtracting(displayedIDs) {
            removePresetState(displayID: displayID)
        }

        let activeKeys = Set(
            brightnessWorkers.keys.map { ControlWriteKey(displayID: $0, kind: .brightness) }
        ).union(controlWorkers.keys).union(
            volumeWorkers.keys.flatMap {
                [
                    ControlWriteKey(displayID: $0, kind: .volume),
                    ControlWriteKey(displayID: $0, kind: .mute),
                ]
            }
        )

        for display in snapshot.displays {
            for capability in display.controls {
                let key = ControlWriteKey(displayID: display.id, kind: capability.kind)
                guard !activeKeys.contains(key), let value = capability.value else { continue }
                if userTargetKeys.contains(key) {
                    let step = Self.normalizedStep(for: value)
                    if capability.status == .available,
                       let target = desiredValues[key],
                       abs(target - value.normalized) <= step / 2 + 0.0001 {
                        userTargetKeys.remove(key)
                        desiredValues[key] = value.normalized
                        lastSuccessfulValues[key] = value.normalized
                    }
                    continue
                }
                desiredValues[key] = value.normalized
                if capability.status == .available {
                    lastSuccessfulValues[key] = value.normalized
                }
            }

            guard presetWorkers[display.id] == nil else { continue }
            guard display.colorPreset?.status == .available,
                  let currentRawValue = display.colorPreset?.currentRawValue else {
                desiredPresetValues[display.id] = nil
                lastVerifiedPresetValues[display.id] = nil
                colorPresetErrors[display.id] = nil
                continue
            }
            desiredPresetValues[display.id] = currentRawValue
            lastVerifiedPresetValues[display.id] = currentRawValue
        }
    }

    private func removePresetState(displayID: CGDirectDisplayID) {
        presetWorkerIDs[displayID] = nil
        presetWorkers.removeValue(forKey: displayID)?.cancel()
        pendingPresetTargets[displayID] = nil
        desiredPresetValues[displayID] = nil
        lastVerifiedPresetValues[displayID] = nil
        colorPresetErrors[displayID] = nil
    }

    private func snapshotValue(
        displayID: CGDirectDisplayID,
        kind: DisplayControlKind
    ) -> Double? {
        snapshot.displays
            .first(where: { $0.id == displayID })?
            .controls.first(where: { $0.kind == kind })?
            .value?.normalized
    }

    private func trustedSnapshotValue(
        displayID: CGDirectDisplayID,
        kind: DisplayControlKind
    ) -> Double? {
        guard let capability = snapshot.displays
            .first(where: { $0.id == displayID })?
            .controls.first(where: { $0.kind == kind }),
            capability.status == .available else {
            return nil
        }
        return capability.value?.normalized
    }

    private func restoreDesiredValue(for key: ControlWriteKey) {
        userTargetKeys.remove(key)
        desiredValues[key] = lastSuccessfulValues[key]
            ?? snapshotValue(displayID: key.displayID, kind: key.kind)
    }

    private func registerDisplayReconfigurationCallback() {
        let context = displayReconfigurationContext
        context.activate(sessionID: sessionID)

        guard !displayCallbackRegistered else { return }
        // Keep this lifetime token alive until callback removal succeeds.
        let opaqueContext = Unmanaged.passRetained(context).toOpaque()
        let error = CGDisplayRegisterReconfigurationCallback(
            displayControlReconfigurationCallback,
            opaqueContext
        )
        guard error == .success else {
            Unmanaged<DisplayControlReconfigurationContext>.fromOpaque(opaqueContext).release()
            context.deactivate()
            logger.error("Display reconfiguration callback registration failed: \(error.rawValue, privacy: .public)")
            return
        }
        displayCallbackRegistered = true
    }

    private func unregisterDisplayReconfigurationCallback() {
        guard displayCallbackRegistered else { return }
        let context = displayReconfigurationContext
        context.deactivate()
        let opaqueContext = Unmanaged.passUnretained(context).toOpaque()
        let error = CGDisplayRemoveReconfigurationCallback(
            displayControlReconfigurationCallback,
            opaqueContext
        )
        guard error == .success else {
            logger.error("Display reconfiguration callback removal failed: \(error.rawValue, privacy: .public)")
            return
        }
        Unmanaged<DisplayControlReconfigurationContext>.fromOpaque(opaqueContext).release()
        displayCallbackRegistered = false
    }

    private func registerWorkspaceObservers(sessionID: UInt64) {
        guard workspaceObservers.isEmpty else { return }

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.suspendForSleep(sessionID: sessionID)
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.suspendForSleep(sessionID: sessionID)
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.resumeAfterWake(sessionID: sessionID)
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.resumeAfterWake(sessionID: sessionID)
            }
        })
    }

    private func unregisterWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    func handleDisplayReconfiguration() {
        handleDisplayReconfiguration(sessionID: sessionID)
    }

    func handleDisplayReconfiguration(sessionID: UInt64) {
        guard started,
              self.sessionID == sessionID,
              !isSuspended,
              !isWakeSettling else {
            return
        }
        scheduleLifecycleRefresh(
            after: timing.reconfigurationRefreshDelayNanos,
            completesWakeSettling: false
        )
    }

    func suspendForSleep() {
        suspendForSleep(sessionID: sessionID)
    }

    private func suspendForSleep(sessionID: UInt64) {
        guard started, self.sessionID == sessionID else { return }
        isSuspended = true
        isWakeSettling = false
        cancelLifecycleRefresh()
        refreshTask?.cancel()
        refreshTask = nil
        cancelPendingWrites()
    }

    func resumeAfterWake() {
        resumeAfterWake(sessionID: sessionID)
    }

    private func resumeAfterWake(sessionID: UInt64) {
        guard started, self.sessionID == sessionID, isSuspended else { return }
        isSuspended = false
        isWakeSettling = true
        scheduleLifecycleRefresh(
            after: timing.wakeRefreshDelayNanos,
            completesWakeSettling: true
        )
    }

    private func scheduleLifecycleRefresh(
        after delayNanos: UInt64,
        completesWakeSettling: Bool
    ) {
        cancelLifecycleRefresh()
        let taskID = UUID()
        let currentSessionID = sessionID
        let sleeper = lifecycleSleeper
        lifecycleRefreshID = taskID
        lifecycleRefreshTask = Task { [weak self, sleeper] in
            do {
                if delayNanos > 0 {
                    try await sleeper.sleep(nanoseconds: delayNanos)
                } else {
                    await Task.yield()
                }
                try Task.checkCancellation()
                guard let self,
                      self.started,
                      self.sessionID == currentSessionID,
                      self.lifecycleRefreshID == taskID,
                      !self.isSuspended else {
                    return
                }
                if completesWakeSettling {
                    guard self.isWakeSettling else { return }
                    self.isWakeSettling = false
                }
                self.lifecycleRefreshTask = nil
                self.lifecycleRefreshID = nil
                self.refresh()
            } catch is CancellationError {
                return
            } catch {
                self?.logger.error("Lifecycle refresh scheduling failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func cancelLifecycleRefresh() {
        lifecycleRefreshTask?.cancel()
        lifecycleRefreshTask = nil
        lifecycleRefreshID = nil
    }

    private func cancelPendingWrites() {
        brightnessWorkers.values.forEach { $0.cancel() }
        controlWorkers.values.forEach { $0.cancel() }
        volumeWorkers.values.forEach { $0.cancel() }
        presetWorkers.values.forEach { $0.cancel() }
        refreshAfterWritesTask?.cancel()

        brightnessWorkers.removeAll()
        brightnessWorkerIDs.removeAll()
        latestBrightnessRequests.removeAll()
        controlWorkers.removeAll()
        controlWorkerIDs.removeAll()
        pendingControlTargets.removeAll()
        volumeWorkers.removeAll()
        volumeWorkerIDs.removeAll()
        pendingVolumeTargets.removeAll()
        presetWorkers.removeAll()
        presetWorkerIDs.removeAll()
        pendingPresetTargets.removeAll()
        desiredPresetValues.removeAll()
        lastVerifiedPresetValues.removeAll()
        colorPresetErrors.removeAll()
        refreshAfterWritesTask = nil
        refreshAfterWritesID = nil
        desiredValues.removeAll()
        lastSuccessfulValues.removeAll()
        userTargetKeys.removeAll()
    }

    private static func normalizedStep(for value: DisplayControlValue?) -> Double {
        guard let value, value.rawMaximum > value.rawMinimum else { return 0.01 }
        return min(max(1 / Double(value.rawMaximum - value.rawMinimum), 0.0001), 1)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
