import Foundation

private struct AudioRouteSourceKey: Hashable {
    let routeID: String
    let processObjectID: UInt32
}

protocol AudioRouteEngineControlling: Sendable {
    func reconcile(plans: [AudioRoutePlan], generation: UInt64) async -> AudioRouteApplyReport
    func update(parameters: [AudioRouteRuntimeParameters]) async -> AudioRouteApplyReport
    func diagnostics() async -> [AudioRouteDiagnosticsSnapshot]
    func stopAll(reason: AudioRouteStopReason) async -> AudioRouteStopReport
}

protocol AudioRouteNativeEngineControlling: AnyObject {
    func beginFadeOut(routeIDs: [String])
    func beginFadeOutAll()
    func reconcile(
        changedPlans: [AudioRoutePlan],
        removingRouteIDs: [String],
        retainedParameters: [AudioRouteNativeRuntimeParameters]
    ) throws
    func update(parameters: [AudioRouteNativeRuntimeParameters]) throws
    func diagnostics() -> [AudioRouteDiagnosticsSnapshot]
    func performMaintenance() -> Bool
    func stopAll(reason: AudioRouteStopReason) -> AudioRouteStopReport
}

actor AudioRouteController: AudioRouteEngineControlling {
    private let nativeEngine: any AudioRouteNativeEngineControlling
    private let fadeOutDelay: Duration
    private var appliedPlans: [AudioRoutePlan] = []
    private var generation: UInt64 = 0
    private var cleanupBlockedMessage: String?
    private var maintenanceTask: Task<Void, Never>?
    private var fadeOperation: UInt64 = 0
    private var pendingFadeOperation: UInt64?

    init(
        nativeEngine: any AudioRouteNativeEngineControlling,
        fadeOutDelay: Duration = .milliseconds(12)
    ) {
        self.nativeEngine = nativeEngine
        self.fadeOutDelay = fadeOutDelay
    }

    func reconcile(
        plans: [AudioRoutePlan],
        generation requestedGeneration: UInt64
    ) async -> AudioRouteApplyReport {
        guard requestedGeneration >= generation else {
            return AudioRouteApplyReport(
                generation: requestedGeneration,
                status: .stale,
                plans: appliedPlans
            )
        }
        generation = requestedGeneration
        cancelPendingFadeOut()

        if let cleanupBlockedMessage {
            return AudioRouteApplyReport(
                generation: requestedGeneration,
                status: .cleanupBlocked(cleanupBlockedMessage),
                plans: appliedPlans
            )
        }
        guard plansAreValid(plans) else {
            return AudioRouteApplyReport(
                generation: requestedGeneration,
                status: .failed(AudioRouteControllerError.malformedPlan.localizedDescription),
                plans: appliedPlans
            )
        }

        guard plans != appliedPlans else {
            return AudioRouteApplyReport(
                generation: requestedGeneration,
                status: .unchanged,
                plans: appliedPlans
            )
        }

        do {
            if hasSameTopology(appliedPlans, plans), !appliedPlans.isEmpty {
                try nativeEngine.update(parameters: nativeParameters(for: plans))
            } else {
                let diff = routeDiff(current: appliedPlans, desired: plans)
                if !diff.removingRouteIDs.isEmpty {
                    let fadeCompleted = await fadeOut(routeIDs: diff.removingRouteIDs)
                    guard fadeCompleted, requestedGeneration == generation else {
                        return AudioRouteApplyReport(
                            generation: requestedGeneration,
                            status: .stale,
                            plans: appliedPlans
                        )
                    }
                }
                try nativeEngine.reconcile(
                    changedPlans: diff.changedPlans,
                    removingRouteIDs: diff.removingRouteIDs,
                    retainedParameters: diff.retainedParameters
                )
                scheduleMaintenance()
            }
            appliedPlans = plans
            return AudioRouteApplyReport(
                generation: requestedGeneration,
                status: .applied,
                plans: plans
            )
        } catch {
            if case let AudioRouteControllerError.routeApplyFailed(message) = error {
                return AudioRouteApplyReport(
                    generation: requestedGeneration,
                    status: .failed(message),
                    plans: appliedPlans
                )
            }
            return failureReport(error: error, generation: requestedGeneration)
        }
    }

    func update(parameters: [AudioRouteRuntimeParameters]) -> AudioRouteApplyReport {
        guard let requestedGeneration = parameters.first?.generation else {
            return AudioRouteApplyReport(
                generation: generation,
                status: .unchanged,
                plans: appliedPlans
            )
        }
        guard parameters.allSatisfy({ $0.generation == requestedGeneration }),
              requestedGeneration >= generation else {
            return AudioRouteApplyReport(
                generation: requestedGeneration,
                status: .stale,
                plans: appliedPlans
            )
        }
        generation = requestedGeneration
        if let cleanupBlockedMessage {
            return AudioRouteApplyReport(
                generation: requestedGeneration,
                status: .cleanupBlocked(cleanupBlockedMessage),
                plans: appliedPlans
            )
        }

        var nativeParameters: [AudioRouteNativeRuntimeParameters] = []
        nativeParameters.reserveCapacity(parameters.count)
        for parameter in parameters {
            guard let plan = appliedPlans.first(where: { $0.id == parameter.routeID }),
                  let sourceIndex = plan.sources.firstIndex(where: {
                      $0.processObjectID == parameter.processObjectID
                  }) else {
                return AudioRouteApplyReport(
                    generation: requestedGeneration,
                    status: .failed("Audio route source is no longer part of the active generation."),
                    plans: appliedPlans
                )
            }
            nativeParameters.append(
                AudioRouteNativeRuntimeParameters(
                    routeID: parameter.routeID,
                    sourceIndex: sourceIndex,
                    targetGain: parameter.targetGain
                )
            )
        }

        do {
            try nativeEngine.update(parameters: nativeParameters)
            appliedPlans = applying(parameters, to: appliedPlans)
            return AudioRouteApplyReport(
                generation: requestedGeneration,
                status: .applied,
                plans: appliedPlans
            )
        } catch {
            return failureReport(error: error, generation: requestedGeneration)
        }
    }

    func diagnostics() -> [AudioRouteDiagnosticsSnapshot] {
        nativeEngine.diagnostics().map { snapshot in
            AudioRouteDiagnosticsSnapshot(
                routeID: snapshot.routeID,
                generation: generation,
                captureCallbackCount: snapshot.captureCallbackCount,
                captureFrameCount: snapshot.captureFrameCount,
                outputCallbackCount: snapshot.outputCallbackCount,
                outputFrameCount: snapshot.outputFrameCount,
                lastCaptureHostTime: snapshot.lastCaptureHostTime,
                lastOutputHostTime: snapshot.lastOutputHostTime,
                ringOccupancyFrames: snapshot.ringOccupancyFrames,
                ringHighWaterFrames: snapshot.ringHighWaterFrames,
                warmupFrameCount: snapshot.warmupFrameCount,
                underrunFrameCount: snapshot.underrunFrameCount,
                overrunFrameCount: snapshot.overrunFrameCount,
                forcedResyncCount: snapshot.forcedResyncCount,
                formatMismatchCount: snapshot.formatMismatchCount,
                nonFiniteSampleCount: snapshot.nonFiniteSampleCount,
                clippedSampleCount: snapshot.clippedSampleCount,
                callbacksInFlight: snapshot.callbacksInFlight,
                fatalCallbackMismatch: snapshot.fatalCallbackMismatch
            )
        }
    }

    func stopAll(reason: AudioRouteStopReason) async -> AudioRouteStopReport {
        cancelPendingFadeOut()
        if reason != .audioServerRestarted {
            let fadeCompleted = await fadeOutAll()
            guard fadeCompleted else {
                return AudioRouteStopReport(
                    succeeded: false,
                    errorMessage: "Audio route stop was superseded by a newer control operation."
                )
            }
        }
        let report = nativeEngine.stopAll(reason: reason)
        scheduleMaintenance()
        if report.succeeded {
            appliedPlans = []
            cleanupBlockedMessage = nil
        } else {
            cleanupBlockedMessage = report.errorMessage ?? "Core Audio cleanup remains blocked."
        }
        return report
    }

    private func failureReport(error: Error, generation: UInt64) -> AudioRouteApplyReport {
        let stopReport = nativeEngine.stopAll(reason: .reconcileFailure)
        scheduleMaintenance()
        if stopReport.succeeded {
            appliedPlans = []
            return AudioRouteApplyReport(
                generation: generation,
                status: .failed(error.localizedDescription),
                plans: []
            )
        }
        let message = stopReport.errorMessage ?? error.localizedDescription
        cleanupBlockedMessage = message
        return AudioRouteApplyReport(
            generation: generation,
            status: .cleanupBlocked(message),
            plans: appliedPlans
        )
    }

    private func plansAreValid(_ plans: [AudioRoutePlan]) -> Bool {
        guard Set(plans.map(\.id)).count == plans.count else { return false }
        return plans.allSatisfy { plan in
            Set(plan.sources.map(\.processObjectID)).count == plan.sources.count
        }
    }

    private func hasSameTopology(_ current: [AudioRoutePlan], _ updated: [AudioRoutePlan]) -> Bool {
        guard current.count == updated.count else { return false }
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        return updated.allSatisfy { plan in
            currentByID[plan.id]?.hasSameTopology(as: plan) == true
        }
    }

    private func routeDiff(
        current: [AudioRoutePlan],
        desired: [AudioRoutePlan]
    ) -> (
        changedPlans: [AudioRoutePlan],
        removingRouteIDs: [String],
        retainedParameters: [AudioRouteNativeRuntimeParameters]
    ) {
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let desiredByID = Dictionary(uniqueKeysWithValues: desired.map { ($0.id, $0) })
        let removingRouteIDs = current.compactMap { plan in
            guard let replacement = desiredByID[plan.id] else { return plan.id }
            return plan.hasSameTopology(as: replacement) ? nil : plan.id
        }
        let changedPlans = desired.filter { plan in
            guard let existing = currentByID[plan.id] else { return true }
            return !existing.hasSameTopology(as: plan)
        }
        let retainedParameters = desired.flatMap { plan -> [AudioRouteNativeRuntimeParameters] in
            guard let existing = currentByID[plan.id],
                  existing.hasSameTopology(as: plan),
                  existing != plan else { return [] }
            return plan.sources.enumerated().map { index, source in
                AudioRouteNativeRuntimeParameters(
                    routeID: plan.id,
                    sourceIndex: index,
                    targetGain: source.linearGain
                )
            }
        }
        return (changedPlans, removingRouteIDs, retainedParameters)
    }

    private func nativeParameters(for plans: [AudioRoutePlan]) -> [AudioRouteNativeRuntimeParameters] {
        plans.flatMap { plan in
            plan.sources.enumerated().map { sourceIndex, source in
                AudioRouteNativeRuntimeParameters(
                    routeID: plan.id,
                    sourceIndex: sourceIndex,
                    targetGain: source.linearGain
                )
            }
        }
    }

    private func applying(
        _ parameters: [AudioRouteRuntimeParameters],
        to plans: [AudioRoutePlan]
    ) -> [AudioRoutePlan] {
        let gainBySource = Dictionary(
            parameters.map {
                (
                    AudioRouteSourceKey(
                        routeID: $0.routeID,
                        processObjectID: $0.processObjectID
                    ),
                    $0.targetGain
                )
            },
            uniquingKeysWith: { _, latest in latest }
        )
        return plans.map { plan in
            AudioRoutePlan(
                outputDeviceUID: plan.outputDeviceUID,
                deviceConfigurationGeneration: plan.deviceConfigurationGeneration,
                sources: plan.sources.map { source in
                    AudioRouteSource(
                        bundleID: source.bundleID,
                        processObjectID: source.processObjectID,
                        linearGain: gainBySource[
                            AudioRouteSourceKey(
                                routeID: plan.id,
                                processObjectID: source.processObjectID
                            )
                        ] ?? source.linearGain
                    )
                }
            )
        }
    }

    private func scheduleMaintenance() {
        guard maintenanceTask == nil else { return }
        maintenanceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.runMaintenance()
        }
    }

    private func fadeOut(routeIDs: [String]) async -> Bool {
        fadeOperation &+= 1
        let operation = fadeOperation
        pendingFadeOperation = operation
        nativeEngine.beginFadeOut(routeIDs: routeIDs)
        await waitForFadeOut()
        guard pendingFadeOperation == operation else { return false }
        pendingFadeOperation = nil
        return true
    }

    private func fadeOutAll() async -> Bool {
        fadeOperation &+= 1
        let operation = fadeOperation
        pendingFadeOperation = operation
        nativeEngine.beginFadeOutAll()
        await waitForFadeOut()
        guard pendingFadeOperation == operation else { return false }
        pendingFadeOperation = nil
        return true
    }

    private func waitForFadeOut() async {
        guard fadeOutDelay > .zero else { return }
        try? await Task.sleep(for: fadeOutDelay)
    }

    private func cancelPendingFadeOut() {
        guard pendingFadeOperation != nil else { return }
        pendingFadeOperation = nil
        fadeOperation &+= 1
        try? nativeEngine.update(parameters: nativeParameters(for: appliedPlans))
    }

    private func runMaintenance() {
        maintenanceTask = nil
        if nativeEngine.performMaintenance() {
            scheduleMaintenance()
        }
    }
}

@available(macOS 14.2, *)
final class NativeAudioRouteEngineController: AudioRouteNativeEngineControlling {
    private let engine: TBAudioRouteEngine
    private var appliedPlansByID: [String: AudioRoutePlan] = [:]

    init(engine: TBAudioRouteEngine = TBAudioRouteEngine()) {
        self.engine = engine
    }

    func beginFadeOut(routeIDs: [String]) {
        routeIDs.forEach { engine.beginFadeOutRoute(withIdentifier: $0) }
    }

    func beginFadeOutAll() {
        engine.beginFadeOutAllRoutes()
    }

    func reconcile(
        changedPlans: [AudioRoutePlan],
        removingRouteIDs: [String],
        retainedParameters: [AudioRouteNativeRuntimeParameters]
    ) throws {
        let previousPlans = removingRouteIDs.compactMap { appliedPlansByID[$0] }
        let previousParameters = retainedParameters.compactMap { parameter -> AudioRouteNativeRuntimeParameters? in
            guard let plan = appliedPlansByID[parameter.routeID],
                  parameter.sourceIndex < plan.sources.count else { return nil }
            return AudioRouteNativeRuntimeParameters(
                routeID: parameter.routeID,
                sourceIndex: parameter.sourceIndex,
                targetGain: plan.sources[parameter.sourceIndex].linearGain
            )
        }
        for routeID in removingRouteIDs {
            guard engine.stopRoute(withIdentifier: routeID) else {
                throw AudioRouteControllerError.cleanupFailed
            }
            appliedPlansByID.removeValue(forKey: routeID)
        }
        var startedRouteIDs: [String] = []
        do {
            for plan in changedPlans {
                try engine.startRoute(
                    withIdentifier: plan.id,
                    outputDeviceUID: plan.outputDeviceUID,
                    processObjectIDs: plan.sources.map { NSNumber(value: $0.processObjectID) },
                    gains: plan.sources.map { NSNumber(value: $0.linearGain) }
                )
                appliedPlansByID[plan.id] = plan
                startedRouteIDs.append(plan.id)
            }
            try update(parameters: retainedParameters)
        } catch {
            var newRoutesStopped = true
            for routeID in startedRouteIDs {
                newRoutesStopped = engine.stopRoute(withIdentifier: routeID) && newRoutesStopped
            }
            startedRouteIDs.forEach { appliedPlansByID.removeValue(forKey: $0) }
            var rollbackSucceeded = newRoutesStopped
            for plan in previousPlans {
                do {
                    try engine.startRoute(
                        withIdentifier: plan.id,
                        outputDeviceUID: plan.outputDeviceUID,
                        processObjectIDs: plan.sources.map { NSNumber(value: $0.processObjectID) },
                        gains: plan.sources.map { NSNumber(value: $0.linearGain) }
                    )
                    appliedPlansByID[plan.id] = plan
                } catch {
                    rollbackSucceeded = false
                }
            }
            do {
                try update(parameters: previousParameters)
            } catch {
                rollbackSucceeded = false
            }
            guard rollbackSucceeded else {
                _ = engine.stopAllRoutes()
                appliedPlansByID.removeAll()
                throw AudioRouteControllerError.cleanupFailed
            }
            throw AudioRouteControllerError.routeApplyFailed(error.localizedDescription)
        }
    }

    func update(parameters: [AudioRouteNativeRuntimeParameters]) throws {
        for parameter in parameters {
            guard engine.updateGain(
                forRoute: parameter.routeID,
                sourceIndex: UInt(parameter.sourceIndex),
                gain: parameter.targetGain
            ) else {
                throw AudioRouteControllerError.gainUpdateFailed
            }
            guard let plan = appliedPlansByID[parameter.routeID],
                  parameter.sourceIndex < plan.sources.count else { continue }
            var sources = plan.sources
            let source = sources[parameter.sourceIndex]
            sources[parameter.sourceIndex] = AudioRouteSource(
                bundleID: source.bundleID,
                processObjectID: source.processObjectID,
                linearGain: parameter.targetGain
            )
            appliedPlansByID[parameter.routeID] = AudioRoutePlan(
                outputDeviceUID: plan.outputDeviceUID,
                deviceConfigurationGeneration: plan.deviceConfigurationGeneration,
                sources: sources
            )
        }
    }

    func diagnostics() -> [AudioRouteDiagnosticsSnapshot] {
        engine.diagnostics().map { snapshot in
            AudioRouteDiagnosticsSnapshot(
                routeID: snapshot.routeIdentifier,
                generation: 0,
                captureCallbackCount: snapshot.captureCallbackCount,
                captureFrameCount: snapshot.captureFrameCount,
                outputCallbackCount: snapshot.outputCallbackCount,
                outputFrameCount: snapshot.outputFrameCount,
                lastCaptureHostTime: snapshot.lastCaptureHostTime,
                lastOutputHostTime: snapshot.lastOutputHostTime,
                ringOccupancyFrames: snapshot.ringOccupancyFrames,
                ringHighWaterFrames: snapshot.ringHighWaterFrames,
                warmupFrameCount: snapshot.warmupFrameCount,
                underrunFrameCount: snapshot.underrunFrameCount,
                overrunFrameCount: snapshot.overrunFrameCount,
                forcedResyncCount: snapshot.forcedResyncCount,
                formatMismatchCount: snapshot.formatMismatchCount,
                nonFiniteSampleCount: snapshot.nonFiniteSampleCount,
                clippedSampleCount: snapshot.clippedSampleCount,
                callbacksInFlight: snapshot.callbacksInFlight,
                fatalCallbackMismatch: snapshot.fatalCallbackMismatch
            )
        }
    }

    func performMaintenance() -> Bool {
        engine.performMaintenance()
    }

    func stopAll(reason: AudioRouteStopReason) -> AudioRouteStopReport {
        if reason == .audioServerRestarted {
            engine.resetAfterAudioServerRestart()
            appliedPlansByID.removeAll()
            return AudioRouteStopReport(succeeded: true, errorMessage: nil)
        }
        let succeeded = engine.stopAllRoutes()
        appliedPlansByID.removeAll()
        return AudioRouteStopReport(
            succeeded: succeeded,
            errorMessage: succeeded ? nil : "One or more Core Audio routes could not be safely stopped."
        )
    }
}

enum AudioRouteControllerError: Error, LocalizedError {
    case cleanupFailed
    case gainUpdateFailed
    case malformedPlan
    case routeApplyFailed(String)

    var errorDescription: String? {
        switch self {
        case .cleanupFailed:
            "The previous Core Audio route could not be safely stopped."
        case .gainUpdateFailed:
            "The running Core Audio route rejected a gain update."
        case .malformedPlan:
            "The audio route plan contains duplicate route or process identifiers."
        case let .routeApplyFailed(message):
            message
        }
    }
}
