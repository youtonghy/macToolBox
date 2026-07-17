import AppKit
import Combine
import CoreGraphics
import Foundation
import OSLog

private let displayControlReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, _, userInfo in
    guard let userInfo else { return }
    let service = Unmanaged<DisplayControlService>.fromOpaque(userInfo).takeUnretainedValue()
    Task { @MainActor in
        service.handleDisplayReconfiguration()
    }
}

struct DisplayControlTiming: Sendable {
    var brightnessFrameDelayNanos: UInt64
    var refreshDebounceNanos: UInt64

    static let live = DisplayControlTiming(
        brightnessFrameDelayNanos: 20_000_000,
        refreshDebounceNanos: 250_000_000
    )
    static let immediateForTests = DisplayControlTiming(
        brightnessFrameDelayNanos: 0,
        refreshDebounceNanos: 0
    )
}

private struct ControlWriteKey: Hashable {
    var displayID: CGDirectDisplayID
    var kind: DisplayControlKind
}

@MainActor
final class DisplayControlService: ObservableObject {
    static let shared = DisplayControlService()

    @Published private(set) var snapshot = DisplayControlSnapshot(timestamp: Date(), displays: [])

    private let provider: DisplayControlProviding
    private let timing: DisplayControlTiming
    private let logger = Logger(subsystem: "ToolBox", category: "DisplayControl")

    private var refreshTask: Task<Void, Never>?
    private var refreshAfterWritesTask: Task<Void, Never>?
    private var refreshAfterWritesID: UUID?

    private var desiredValues: [ControlWriteKey: Double] = [:]
    private var lastSuccessfulValues: [ControlWriteKey: Double] = [:]
    private var userTargetKeys = Set<ControlWriteKey>()

    private var latestBrightnessTargets: [CGDirectDisplayID: Double] = [:]
    private var brightnessWorkers: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var brightnessWorkerIDs: [CGDirectDisplayID: UUID] = [:]

    private var pendingControlTargets: [ControlWriteKey: Double] = [:]
    private var controlWorkers: [ControlWriteKey: Task<Void, Never>] = [:]
    private var controlWorkerIDs: [ControlWriteKey: UUID] = [:]

    private var pendingVolumeTargets: [CGDirectDisplayID: Double] = [:]
    private var volumeWorkers: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var volumeWorkerIDs: [CGDirectDisplayID: UUID] = [:]

    private var displayCallbackRegistered = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isSuspended = false

    init(
        provider: DisplayControlProviding = DarwinDisplayControlProvider(),
        timing: DisplayControlTiming = .live
    ) {
        self.provider = provider
        self.timing = timing
    }

    func start() {
        registerDisplayReconfigurationCallback()
        registerWorkspaceObservers()
        refresh()
    }

    func stop() {
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

    @discardableResult
    func writeValue(
        displayID: CGDirectDisplayID,
        kind: DisplayControlKind,
        normalizedValue: Double
    ) async throws -> DisplayControlValue {
        try await provider.writeValue(
            displayID: displayID,
            kind: kind,
            normalizedValue: normalizedValue
        )
    }

    func presentedValue(displayID: CGDirectDisplayID, kind: DisplayControlKind) -> Double? {
        desiredValues[ControlWriteKey(displayID: displayID, kind: kind)]
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
        smooth: Bool = true
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
        latestBrightnessTargets[displayID] = target
        guard brightnessWorkers[displayID] == nil else { return }

        let workerID = UUID()
        brightnessWorkerIDs[displayID] = workerID
        brightnessWorkers[displayID] = Task { [weak self] in
            await self?.runBrightnessWorker(
                displayID: displayID,
                workerID: workerID,
                smooth: smooth
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
        workerID: UUID,
        smooth: Bool
    ) async {
        let key = ControlWriteKey(displayID: displayID, kind: .brightness)
        var transient = lastSuccessfulValues[key] ?? trustedSnapshotValue(
            displayID: displayID,
            kind: .brightness
        )

        do {
            while let target = latestBrightnessTargets[displayID] {
                try Task.checkCancellation()
                let next: Double
                if !smooth || transient == nil {
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

                let value = try await provider.writeValue(
                    displayID: displayID,
                    kind: .brightness,
                    normalizedValue: next
                )
                try Task.checkCancellation()
                transient = value.normalized
                lastSuccessfulValues[key] = value.normalized

                if let latestTarget = latestBrightnessTargets[displayID],
                   abs(latestTarget - value.normalized) < 0.0001 {
                    latestBrightnessTargets[displayID] = nil
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
            latestBrightnessTargets[displayID] = nil
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

    private func scheduleRefreshWhenIdle() {
        guard brightnessWorkers.isEmpty, controlWorkers.isEmpty, volumeWorkers.isEmpty else {
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
        }
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
        guard !displayCallbackRegistered else { return }
        CGDisplayRegisterReconfigurationCallback(
            displayControlReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        displayCallbackRegistered = true
    }

    private func unregisterDisplayReconfigurationCallback() {
        guard displayCallbackRegistered else { return }
        CGDisplayRemoveReconfigurationCallback(
            displayControlReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        displayCallbackRegistered = false
    }

    private func registerWorkspaceObservers() {
        guard workspaceObservers.isEmpty else { return }

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.suspendForSleep() }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.suspendForSleep() }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resumeAfterWake() }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resumeAfterWake() }
        })
    }

    private func unregisterWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    fileprivate func handleDisplayReconfiguration() {
        guard !isSuspended else { return }
        Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                try Task.checkCancellation()
                self?.refresh()
            } catch {
                return
            }
        }
    }

    private func suspendForSleep() {
        isSuspended = true
        refreshTask?.cancel()
        refreshTask = nil
        cancelPendingWrites()
    }

    private func resumeAfterWake() {
        guard isSuspended else { return }
        isSuspended = false
        Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                try Task.checkCancellation()
                self?.refresh()
            } catch {
                return
            }
        }
    }

    private func cancelPendingWrites() {
        brightnessWorkers.values.forEach { $0.cancel() }
        controlWorkers.values.forEach { $0.cancel() }
        volumeWorkers.values.forEach { $0.cancel() }
        refreshAfterWritesTask?.cancel()

        brightnessWorkers.removeAll()
        brightnessWorkerIDs.removeAll()
        latestBrightnessTargets.removeAll()
        controlWorkers.removeAll()
        controlWorkerIDs.removeAll()
        pendingControlTargets.removeAll()
        volumeWorkers.removeAll()
        volumeWorkerIDs.removeAll()
        pendingVolumeTargets.removeAll()
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
