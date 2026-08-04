import Foundation

final class SwiftAudioRouteEngineAdapter: AudioRouteNativeEngineControlling {
    private let runtime: any AudioRouteRuntimeControlling
    private var plansByID: [String: AudioRoutePlan] = [:]
    private var mutedRouteIDs: Set<String> = []
    private var generation: UInt64 = 0
    private var pendingFailure: Error?

    init(runtime: any AudioRouteRuntimeControlling) {
        self.runtime = runtime
    }

    func beginFadeOut(routeIDs: [String]) {
        let requestedRouteIDs = Set(routeIDs).intersection(plansByID.keys)
        guard !requestedRouteIDs.isEmpty else { return }

        let candidateMutedRouteIDs = mutedRouteIDs.union(requestedRouteIDs)
        do {
            _ = try converge(
                plansByID: plansByID,
                mutedRouteIDs: candidateMutedRouteIDs
            )
        } catch {
            pendingFailure = error
        }
        mutedRouteIDs = candidateMutedRouteIDs
    }

    func beginFadeOutAll() {
        beginFadeOut(routeIDs: Array(plansByID.keys))
    }

    func reconcile(
        changedPlans: [AudioRoutePlan],
        removingRouteIDs: [String],
        retainedParameters: [AudioRouteNativeRuntimeParameters]
    ) throws {
        try throwPendingFailure()

        var candidatePlans = plansByID
        removingRouteIDs.forEach { candidatePlans.removeValue(forKey: $0) }
        for plan in changedPlans {
            candidatePlans[plan.id] = plan
        }
        try apply(retainedParameters, to: &candidatePlans)

        let changedRouteIDs = Set(changedPlans.map(\.id))
        let candidateMutedRouteIDs = mutedRouteIDs
            .intersection(candidatePlans.keys)
            .subtracting(changedRouteIDs)
        _ = try converge(
            plansByID: candidatePlans,
            mutedRouteIDs: candidateMutedRouteIDs
        )
        plansByID = candidatePlans
        mutedRouteIDs = candidateMutedRouteIDs
    }

    func update(parameters: [AudioRouteNativeRuntimeParameters]) throws {
        guard !parameters.isEmpty else { return }

        var candidatePlans = plansByID
        try apply(parameters, to: &candidatePlans)
        let candidateMutedRouteIDs = mutedRouteIDs.subtracting(
            parameters.map(\.routeID)
        )
        _ = try converge(
            plansByID: candidatePlans,
            mutedRouteIDs: candidateMutedRouteIDs
        )
        plansByID = candidatePlans
        mutedRouteIDs = candidateMutedRouteIDs
    }

    func diagnostics() -> [AudioRouteDiagnosticsSnapshot] {
        runtime.snapshot()
    }

    var fadeOutDuration: Duration {
        // The runtime uses rampFrames = max(1, sampleRate * 0.010) ≈ 10ms at any rate.
        // The worst-case callback period is estimated at 2048/44100 ≈ 46ms.
        // Total: 1 callback period + 1 ramp period = 46ms + 10ms.
        // Round up to 60ms for safety.
        .milliseconds(60)
    }

    func performMaintenance() -> Bool {
        runtime.performMaintenance()
    }

    func stopAll(reason: AudioRouteStopReason) -> AudioRouteStopReport {
        let report = runtime.shutdown(reason: reason)
        guard report.succeeded else { return report }

        plansByID = [:]
        mutedRouteIDs = []
        pendingFailure = nil
        return report
    }

    private func converge(
        plansByID: [String: AudioRoutePlan],
        mutedRouteIDs: Set<String>
    ) throws -> AudioRuntimeApplyResult {
        if self.plansByID != plansByID || self.mutedRouteIDs != mutedRouteIDs {
            generation &+= 1
        }
        return try runtime.converge(
            to: AudioRuntimeIntent(
                generation: generation,
                plansByID: plansByID,
                mutedRouteIDs: mutedRouteIDs
            )
        )
    }

    private func apply(
        _ parameters: [AudioRouteNativeRuntimeParameters],
        to plansByID: inout [String: AudioRoutePlan]
    ) throws {
        for parameter in parameters {
            guard let plan = plansByID[parameter.routeID],
                  plan.sources.indices.contains(parameter.sourceIndex) else {
                throw AudioRouteControllerError.gainUpdateFailed
            }

            var sources = plan.sources
            let source = sources[parameter.sourceIndex]
            sources[parameter.sourceIndex] = AudioRouteSource(
                bundleID: source.bundleID,
                processObjectID: source.processObjectID,
                linearGain: parameter.targetGain
            )
            plansByID[parameter.routeID] = AudioRoutePlan(
                outputDeviceUID: plan.outputDeviceUID,
                deviceConfigurationGeneration: plan.deviceConfigurationGeneration,
                sources: sources
            )
        }
    }

    private func throwPendingFailure() throws {
        guard let pendingFailure else { return }
        self.pendingFailure = nil
        throw pendingFailure
    }
}
