import CoreAudio
import Foundation
import XCTest
@testable import ToolBoxCore

final class AudioRouteRuntimeTests: XCTestCase {
    func testSameIntentAndObservationIsIdempotent() throws {
        let hal = ScriptedCoreAudioHAL(observation: AudioRouteTestFixtures.observation())
        let runtime = AudioRouteRuntime(hal: hal)
        let intent = AudioRouteTestFixtures.intent()

        XCTAssertEqual(try runtime.converge(to: intent), .applied)
        XCTAssertEqual(try runtime.converge(to: intent), .unchanged)
        XCTAssertEqual(hal.executedTransactions.count, 1)
    }

    func testParameterOnlyChangeUpdatesHALWithoutRebuilding() throws {
        let hal = ScriptedCoreAudioHAL(observation: AudioRouteTestFixtures.observation())
        let runtime = AudioRouteRuntime(hal: hal)
        _ = try runtime.converge(to: AudioRouteTestFixtures.intent(gain: 1))

        XCTAssertEqual(
            try runtime.converge(to: AudioRouteTestFixtures.intent(generation: 2, gain: 2)),
            .applied
        )

        XCTAssertEqual(hal.executedTransactions.count, 1)
        XCTAssertEqual(hal.updatedIntents.last?.plansByID["output-A"]?.sources.first?.linearGain, 2)
    }

    func testChangedTapFormatRebuildsUnchangedIntent() throws {
        let hal = ScriptedCoreAudioHAL(
            observation: AudioRouteTestFixtures.observation(tapSampleRate: 44_100)
        )
        let runtime = AudioRouteRuntime(hal: hal)
        let intent = AudioRouteTestFixtures.intent()
        _ = try runtime.converge(to: intent)

        hal.observation = AudioRouteTestFixtures.observation(tapSampleRate: 48_000)

        XCTAssertEqual(try runtime.converge(to: intent), .applied)
        XCTAssertEqual(hal.executedTransactions.count, 2)
    }

    func testCandidateFailureKeepsSafePreviousRealization() throws {
        let hal = ScriptedCoreAudioHAL(observation: AudioRouteTestFixtures.observation())
        let runtime = AudioRouteRuntime(hal: hal)
        _ = try runtime.converge(to: AudioRouteTestFixtures.intent(outputUID: "output-A"))
        hal.failNext(stage: .startCapture, status: -1)
        hal.observation = AudioRouteTestFixtures.observation(outputUID: "output-B")

        XCTAssertThrowsError(
            try runtime.converge(to: AudioRouteTestFixtures.intent(outputUID: "output-B"))
        ) { error in
            XCTAssertEqual(
                error as? AudioRuntimeFailure,
                .prepareFailed(routeID: "output-B", stage: .startCapture, status: -1)
            )
        }
        XCTAssertEqual(hal.activeOutputUIDs, ["output-A"])
    }

    func testIncompleteCandidateRollsBackAndReportsCommitFailure() throws {
        let hal = ScriptedCoreAudioHAL(observation: AudioRouteTestFixtures.observation())
        let runtime = AudioRouteRuntime(hal: hal)
        hal.omitRealizedKeyOnNextReceipt = true

        XCTAssertThrowsError(try runtime.converge(to: AudioRouteTestFixtures.intent())) { error in
            guard case let AudioRuntimeFailure.commitFailed(
                routeID,
                stage,
                _,
                rollbackSucceeded
            ) = error else {
                return XCTFail("Expected a typed commit failure, got \(error)")
            }
            XCTAssertEqual(routeID, "output-A")
            XCTAssertEqual(stage.rawValue, HALStage.commit.rawValue)
            XCTAssertTrue(rollbackSucceeded)
        }
        XCTAssertTrue(hal.activeOutputUIDs.isEmpty)
    }

    func testDeferredRollbackBlocksShutdownWhileCleanupRemainsPending() throws {
        let hal = ScriptedCoreAudioHAL(observation: AudioRouteTestFixtures.observation())
        let runtime = AudioRouteRuntime(hal: hal)
        hal.omitRealizedKeyOnNextReceipt = true
        let cleanupFailure = HALCleanupFailure(
            routeID: "output-A",
            resource: .processTap,
            objectID: 77,
            stage: .destroyTap,
            status: -1
        )
        hal.rollbackResultOnNextReceipt = .deferred(failures: [cleanupFailure])

        XCTAssertThrowsError(try runtime.converge(to: AudioRouteTestFixtures.intent())) { error in
            XCTAssertEqual(
                error as? AudioRuntimeFailure,
                .cleanupDeferred(routeID: "output-A", failures: [cleanupFailure])
            )
        }

        let report = runtime.shutdown(reason: .reconcileFailure)
        XCTAssertFalse(report.succeeded)
        XCTAssertNotNil(report.errorMessage)
    }

    func testMaintenanceRetriesDeferredRollbackAndUnblocksRuntime() throws {
        let hal = ScriptedCoreAudioHAL(observation: AudioRouteTestFixtures.observation())
        let runtime = AudioRouteRuntime(hal: hal)
        hal.omitRealizedKeyOnNextReceipt = true
        hal.rollbackResultsOnNextReceipt = [
            .deferred(failures: [
                HALCleanupFailure(
                    routeID: "output-A",
                    resource: .processTap,
                    objectID: 77,
                    stage: .destroyTap,
                    status: -1
                ),
            ]),
            .succeeded,
        ]

        XCTAssertThrowsError(try runtime.converge(to: AudioRouteTestFixtures.intent()))
        XCTAssertFalse(runtime.performMaintenance())
        XCTAssertEqual(
            try runtime.converge(to: AudioRouteTestFixtures.intent()),
            .applied
        )
    }

    func testIncompleteReplacementRollsBackToPreviousRealization() throws {
        let hal = ScriptedCoreAudioHAL(observation: AudioRouteTestFixtures.observation())
        let runtime = AudioRouteRuntime(hal: hal)
        _ = try runtime.converge(to: AudioRouteTestFixtures.intent(outputUID: "output-A"))
        hal.observation = AudioRouteTestFixtures.observation(outputUID: "output-B")
        hal.omitRealizedKeyOnNextReceipt = true

        XCTAssertThrowsError(
            try runtime.converge(to: AudioRouteTestFixtures.intent(outputUID: "output-B"))
        )
        XCTAssertEqual(hal.activeOutputUIDs, ["output-A"])
    }

    func testSourceSpecificFailureIgnoresUnrelatedTransaction() throws {
        let hal = ScriptedCoreAudioHAL(observation: AudioRouteTestFixtures.observation())
        let runtime = AudioRouteRuntime(hal: hal)
        hal.failNext(sourceID: 99, stage: .startCapture)

        XCTAssertEqual(
            try runtime.converge(to: AudioRouteTestFixtures.intent()),
            .applied
        )
    }
}

final class ScriptedCoreAudioHAL: CoreAudioHALPort, @unchecked Sendable {
    var observation: HALObservationSnapshot
    let capabilities: Set<HALCapability>
    private(set) var executedTransactions: [HALTransaction] = []
    private(set) var updatedIntents: [AudioRuntimeIntent] = []
    var operationLog: [HALOperation] = []
    private(set) var activeOutputUIDs: Set<String> = []
    private(set) var activeSourceIDs: Set<UInt32> = []
    var omitRealizedKeyOnNextReceipt = false
    var rollbackResultOnNextReceipt: HALRollbackResult = .succeeded
    var rollbackResultsOnNextReceipt: [HALRollbackResult] = []

    private var nextFailure: (sourceID: UInt32?, stage: HALStage, status: OSStatus)?
    private var persistentFailures: [UInt32: HALStage] = [:]
    private var healthSamples: [UInt32: AudioRouteHealthSample] = [:]

    init(
        observation: HALObservationSnapshot,
        capabilities: Set<HALCapability> = []
    ) {
        self.observation = observation
        self.capabilities = capabilities
    }

    func observe(_ request: HALObservationRequest) throws -> HALObservationSnapshot {
        observation
    }

    func execute(_ transaction: HALTransaction) throws -> HALTransactionReceipt {
        executedTransactions.append(transaction)

        if let failure = nextFailure,
           failure.sourceID.map(transaction.sourceIDs.contains) ?? true {
            nextFailure = nil
            throw AudioRuntimeFailure.prepareFailed(
                routeID: transaction.routeID,
                stage: failure.stage,
                status: failure.status
            )
        }
        if let sourceID = transaction.sourceIDs.first(where: { persistentFailures[$0] != nil }),
           let stage = persistentFailures[sourceID] {
            throw AudioRuntimeFailure.prepareFailed(
                routeID: transaction.routeID,
                stage: stage,
                status: -1
            )
        }

        let previousOutputUIDs = activeOutputUIDs
        let previousSourceIDs = activeSourceIDs
        let configuredRollbackResults = rollbackResultsOnNextReceipt.isEmpty
            ? [rollbackResultOnNextReceipt]
            : rollbackResultsOnNextReceipt
        let rollbackSequence = RollbackSequence(configuredRollbackResults)
        rollbackResultsOnNextReceipt = []
        rollbackResultOnNextReceipt = .succeeded
        let realizedKeys = transaction.intent.plansByID.keys.reduce(
            into: [String: RealizationKey]()
        ) { result, routeID in
            result[routeID] = RealizationKey(
                routeID: routeID,
                intent: transaction.intent,
                observation: transaction.observation
            )
        }

        activeOutputUIDs = Set(transaction.intent.plansByID.values.map(\.outputDeviceUID))
        activeSourceIDs = Set(
            transaction.intent.plansByID.values.flatMap { $0.sources.map(\.processObjectID) }
        )

        var receiptKeys = realizedKeys
        if omitRealizedKeyOnNextReceipt {
            omitRealizedKeyOnNextReceipt = false
            if let routeID = receiptKeys.keys.sorted().first {
                receiptKeys.removeValue(forKey: routeID)
            }
        }

        return HALTransactionReceipt(
            realizedKeysByRouteID: receiptKeys,
            activeOutputUIDs: activeOutputUIDs,
            rollback: { [weak self] in
                self?.activeOutputUIDs = previousOutputUIDs
                self?.activeSourceIDs = previousSourceIDs
                return rollbackSequence.next()
            }
        )
    }

    func updateParameters(_ intent: AudioRuntimeIntent) throws {
        updatedIntents.append(intent)
    }

    func changes(for observations: Set<HALObservation>) -> AsyncStream<HALChange> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func failNext(stage: HALStage, status: OSStatus) {
        nextFailure = (nil, stage, status)
    }

    func failNext(sourceID: UInt32, stage: HALStage) {
        nextFailure = (sourceID, stage, -1)
    }

    func failEveryTransaction(sourceID: UInt32, stage: HALStage) {
        persistentFailures[sourceID] = stage
    }

    func setHealthSample(_ sourceID: UInt32, _ sample: AudioRouteHealthSample) {
        healthSamples[sourceID] = sample
    }
}

private final class RollbackSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [HALRollbackResult]

    init(_ results: [HALRollbackResult]) {
        self.results = results
    }

    func next() -> HALRollbackResult {
        lock.lock()
        defer { lock.unlock() }
        if results.count > 1 {
            return results.removeFirst()
        }
        return results[0]
    }
}
