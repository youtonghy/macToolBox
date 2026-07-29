import CoreAudio
import Foundation

final class AudioRouteRuntime: AudioRouteRuntimeControlling {
    private struct PendingCleanup {
        let routeID: String
        let receipt: HALTransactionReceipt
    }

    private let hal: any CoreAudioHALPort
    private var desiredIntent: AudioRuntimeIntent?
    private var realizedKeysByRouteID: [String: RealizationKey] = [:]
    private var activeReceipt: HALTransactionReceipt?
    private var pendingCleanups: [PendingCleanup] = []
    private var lastFailure: AudioRuntimeFailure?

    init(hal: any CoreAudioHALPort) {
        self.hal = hal
    }

    func converge(to intent: AudioRuntimeIntent) throws -> AudioRuntimeApplyResult {
        if !pendingCleanups.isEmpty,
           let lastFailure {
            throw lastFailure
        }

        do {
            try validate(intent)
            let observation = try hal.observe(HALObservationRequest(intent: intent))
            let candidateKeys = try realizationKeys(for: intent, observation: observation)

            if desiredIntent == intent, realizedKeysByRouteID == candidateKeys {
                return .unchanged
            }
            if desiredIntent == nil, intent.plansByID.isEmpty, realizedKeysByRouteID.isEmpty {
                desiredIntent = intent
                return .unchanged
            }

            let routeID = candidateKeys.keys.sorted().first
                ?? realizedKeysByRouteID.keys.sorted().first
                ?? ""
            let transaction = HALTransaction(
                kind: .prepareCandidate,
                routeID: routeID,
                sourceIDs: sourceIDs(in: intent),
                intent: intent,
                observation: observation,
                replacingKeysByRouteID: realizedKeysByRouteID
            )
            let receipt = try hal.execute(transaction)

            guard receipt.realizedKeysByRouteID == candidateKeys,
                  receipt.activeOutputUIDs == Set(intent.plansByID.values.map(\.outputDeviceUID))
            else {
                try throwIncompleteCommit(routeID: routeID, receipt: receipt)
            }

            desiredIntent = intent
            realizedKeysByRouteID = candidateKeys
            activeReceipt = receipt
            lastFailure = nil
            return .applied
        } catch let failure as AudioRuntimeFailure {
            lastFailure = failure
            throw failure
        }
    }

    func snapshot() -> [AudioRouteDiagnosticsSnapshot] {
        []
    }

    func performMaintenance() -> Bool {
        var deferred: [PendingCleanup] = []
        for cleanup in pendingCleanups {
            switch cleanup.receipt.rollback() {
            case .succeeded:
                continue
            case let .deferred(failures):
                deferred.append(cleanup)
                lastFailure = .cleanupDeferred(
                    routeID: cleanup.routeID,
                    failures: failures
                )
            }
        }
        pendingCleanups = deferred
        let halCleanupPending: Bool
        switch hal.performMaintenance() {
        case .succeeded:
            halCleanupPending = false
        case let .deferred(failures):
            halCleanupPending = true
            lastFailure = .cleanupDeferred(
                routeID: failures.first?.routeID ?? "",
                failures: failures
            )
        }
        if deferred.isEmpty, !halCleanupPending {
            lastFailure = nil
        }
        return !deferred.isEmpty || halCleanupPending
    }

    func shutdown(reason: AudioRouteStopReason) -> AudioRouteStopReport {
        if !pendingCleanups.isEmpty {
            return AudioRouteStopReport(
                succeeded: false,
                errorMessage: lastFailure.map { String(describing: $0) }
                    ?? "Core Audio cleanup remains pending."
            )
        }
        if case let .deferred(failures) = hal.performMaintenance() {
            let failure = AudioRuntimeFailure.cleanupDeferred(
                routeID: failures.first?.routeID ?? "",
                failures: failures
            )
            lastFailure = failure
            return AudioRouteStopReport(
                succeeded: false,
                errorMessage: String(describing: failure)
            )
        }
        guard let desiredIntent, !realizedKeysByRouteID.isEmpty else {
            clearActiveState()
            return AudioRouteStopReport(succeeded: true, errorMessage: nil)
        }

        let emptyIntent = AudioRuntimeIntent(
            generation: desiredIntent.generation &+ 1,
            plansByID: [:],
            mutedRouteIDs: []
        )

        do {
            let observation = try hal.observe(HALObservationRequest(intent: emptyIntent))
            let routeID = realizedKeysByRouteID.keys.sorted().first ?? ""
            let receipt = try hal.execute(
                HALTransaction(
                    kind: .shutdown,
                    routeID: routeID,
                    sourceIDs: sourceIDs(in: desiredIntent),
                    intent: emptyIntent,
                    observation: observation,
                    replacingKeysByRouteID: realizedKeysByRouteID
                )
            )
            guard receipt.realizedKeysByRouteID.isEmpty,
                  receipt.activeOutputUIDs.isEmpty else {
                try throwIncompleteCommit(routeID: routeID, receipt: receipt)
            }
            clearActiveState()
            return AudioRouteStopReport(succeeded: true, errorMessage: nil)
        } catch let failure as AudioRuntimeFailure {
            lastFailure = failure
            return AudioRouteStopReport(
                succeeded: false,
                errorMessage: String(describing: failure)
            )
        } catch {
            return AudioRouteStopReport(
                succeeded: false,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func validate(_ intent: AudioRuntimeIntent) throws {
        for (routeID, plan) in intent.plansByID {
            guard routeID == plan.id else {
                throw AudioRuntimeFailure.invalidIntent(
                    "Route key \(routeID) does not match output UID \(plan.id)."
                )
            }
            guard Set(plan.sources.map(\.processObjectID)).count == plan.sources.count else {
                throw AudioRuntimeFailure.invalidIntent(
                    "Route \(routeID) contains duplicate process identifiers."
                )
            }
        }
    }

    private func realizationKeys(
        for intent: AudioRuntimeIntent,
        observation: HALObservationSnapshot
    ) throws -> [String: RealizationKey] {
        try intent.plansByID.keys.reduce(into: [String: RealizationKey]()) { result, routeID in
            guard let key = RealizationKey(
                routeID: routeID,
                intent: intent,
                observation: observation
            ) else {
                throw AudioRuntimeFailure.invalidIntent(
                    "HAL observation is incomplete for route \(routeID)."
                )
            }
            result[routeID] = key
        }
    }

    private func sourceIDs(in intent: AudioRuntimeIntent) -> [UInt32] {
        Set(
            intent.plansByID.values.flatMap { plan in
                plan.sources.map(\.processObjectID)
            }
        ).sorted()
    }

    private func throwIncompleteCommit(
        routeID: String,
        receipt: HALTransactionReceipt
    ) throws -> Never {
        switch receipt.rollback() {
        case .succeeded:
            throw AudioRuntimeFailure.commitFailed(
                routeID: routeID,
                stage: .commit,
                status: -1,
                rollbackSucceeded: true
            )
        case let .deferred(failures):
            pendingCleanups.append(PendingCleanup(routeID: routeID, receipt: receipt))
            throw AudioRuntimeFailure.cleanupDeferred(
                routeID: routeID,
                failures: failures
            )
        }
    }

    private func clearActiveState() {
        desiredIntent = nil
        realizedKeysByRouteID = [:]
        activeReceipt = nil
        pendingCleanups = []
        lastFailure = nil
    }
}
