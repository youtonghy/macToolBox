import XCTest
@testable import ToolBox

final class SwiftAudioRouteEngineAdapterTests: XCTestCase {
    func testReconcileReconstructsCompleteDesiredPlans() throws {
        let runtime = RecordingAudioRouteRuntime()
        let adapter = SwiftAudioRouteEngineAdapter(runtime: runtime)
        let first = plan(outputUID: "output-A", processObjectID: 42, gain: 1)
        let second = plan(outputUID: "output-B", processObjectID: 43, gain: 1)
        try adapter.reconcile(
            changedPlans: [first, second],
            removingRouteIDs: [],
            retainedParameters: []
        )

        let updatedFirst = plan(outputUID: "output-A", processObjectID: 42, gain: 2)
        try adapter.reconcile(
            changedPlans: [],
            removingRouteIDs: ["output-B"],
            retainedParameters: [
                AudioRouteNativeRuntimeParameters(
                    routeID: "output-A",
                    sourceIndex: 0,
                    targetGain: 2
                )
            ]
        )

        XCTAssertEqual(runtime.intents.last?.plansByID, ["output-A": updatedFirst])
    }

    func testGainUpdateConvergesACompleteIntent() throws {
        let runtime = RecordingAudioRouteRuntime()
        let adapter = SwiftAudioRouteEngineAdapter(runtime: runtime)
        try adapter.reconcile(
            changedPlans: [plan(outputUID: "output-A", processObjectID: 42, gain: 1)],
            removingRouteIDs: [],
            retainedParameters: []
        )

        try adapter.update(parameters: [
            AudioRouteNativeRuntimeParameters(
                routeID: "output-A",
                sourceIndex: 0,
                targetGain: 2.5
            )
        ])

        XCTAssertEqual(
            runtime.intents.last?.plansByID["output-A"]?.sources.first?.linearGain,
            2.5
        )
        XCTAssertEqual(runtime.intents.last?.plansByID.count, 1)
    }

    func testRepeatedNoOpReconcileKeepsGenerationStableAndRuntimeIdempotent() throws {
        let hal = ScriptedCoreAudioHAL(observation: AudioRouteTestFixtures.observation())
        let adapter = SwiftAudioRouteEngineAdapter(runtime: AudioRouteRuntime(hal: hal))
        let route = plan(outputUID: "output-A", processObjectID: 42, gain: 1)

        try adapter.reconcile(
            changedPlans: [route],
            removingRouteIDs: [],
            retainedParameters: []
        )
        try adapter.reconcile(
            changedPlans: [],
            removingRouteIDs: [],
            retainedParameters: []
        )

        XCTAssertEqual(hal.executedTransactions.count, 1)
    }

    func testFadeFailureIsThrownByNextReconcile() throws {
        let runtime = RecordingAudioRouteRuntime()
        let adapter = SwiftAudioRouteEngineAdapter(runtime: runtime)
        try adapter.reconcile(
            changedPlans: [plan(outputUID: "output-A", processObjectID: 42, gain: 1)],
            removingRouteIDs: [],
            retainedParameters: []
        )
        runtime.nextError = AudioRuntimeFailure.audioServerRestarted

        adapter.beginFadeOut(routeIDs: ["output-A"])

        XCTAssertNoThrow(
            try adapter.update(parameters: [
                AudioRouteNativeRuntimeParameters(
                    routeID: "output-A",
                    sourceIndex: 0,
                    targetGain: 1
                )
            ])
        )

        XCTAssertThrowsError(
            try adapter.reconcile(
                changedPlans: [],
                removingRouteIDs: [],
                retainedParameters: []
            )
        ) { error in
            XCTAssertEqual(error as? AudioRuntimeFailure, .audioServerRestarted)
        }
        XCTAssertEqual(runtime.intents.last?.mutedRouteIDs, [])
    }

    func testParameterUpdateCancelsPendingFadeMute() throws {
        let runtime = RecordingAudioRouteRuntime()
        let adapter = SwiftAudioRouteEngineAdapter(runtime: runtime)
        try adapter.reconcile(
            changedPlans: [plan(outputUID: "output-A", processObjectID: 42, gain: 1)],
            removingRouteIDs: [],
            retainedParameters: []
        )
        adapter.beginFadeOut(routeIDs: ["output-A"])

        try adapter.update(parameters: [
            AudioRouteNativeRuntimeParameters(
                routeID: "output-A",
                sourceIndex: 0,
                targetGain: 1
            )
        ])

        XCTAssertEqual(runtime.intents.last?.mutedRouteIDs, [])
    }

    func testReplacingFadedRouteClearsMuteForNewKernel() throws {
        let runtime = RecordingAudioRouteRuntime()
        let adapter = SwiftAudioRouteEngineAdapter(runtime: runtime)
        let initial = plan(outputUID: "output-A", processObjectID: 42, gain: 1)
        try adapter.reconcile(
            changedPlans: [initial],
            removingRouteIDs: [],
            retainedParameters: []
        )
        adapter.beginFadeOut(routeIDs: ["output-A"])

        try adapter.reconcile(
            changedPlans: [plan(outputUID: "output-A", processObjectID: 43, gain: 1)],
            removingRouteIDs: ["output-A"],
            retainedParameters: []
        )

        XCTAssertEqual(runtime.intents.last?.mutedRouteIDs, [])
    }

    func testStopAllClearsAdapterStateAfterRuntimeShutdown() throws {
        let runtime = RecordingAudioRouteRuntime()
        let adapter = SwiftAudioRouteEngineAdapter(runtime: runtime)
        try adapter.reconcile(
            changedPlans: [plan(outputUID: "output-A", processObjectID: 42, gain: 1)],
            removingRouteIDs: [],
            retainedParameters: []
        )

        XCTAssertTrue(adapter.stopAll(reason: .serviceStopped).succeeded)
        try adapter.reconcile(
            changedPlans: [plan(outputUID: "output-B", processObjectID: 43, gain: 1)],
            removingRouteIDs: [],
            retainedParameters: []
        )

        XCTAssertEqual(runtime.intents.last?.plansByID.keys.sorted(), ["output-B"])
        XCTAssertEqual(runtime.shutdownReasons, [.serviceStopped])
    }

    private func plan(
        outputUID: String,
        processObjectID: UInt32,
        gain: Float
    ) -> AudioRoutePlan {
        AudioRoutePlan(
            outputDeviceUID: outputUID,
            sources: [
                AudioRouteSource(
                    bundleID: "com.example.\(processObjectID)",
                    processObjectID: processObjectID,
                    linearGain: gain
                )
            ]
        )
    }
}

private final class RecordingAudioRouteRuntime: AudioRouteRuntimeControlling {
    private(set) var intents: [AudioRuntimeIntent] = []
    private(set) var shutdownReasons: [AudioRouteStopReason] = []
    var nextError: Error?

    func converge(to intent: AudioRuntimeIntent) throws -> AudioRuntimeApplyResult {
        intents.append(intent)
        if let nextError {
            self.nextError = nil
            throw nextError
        }
        return .applied
    }

    func snapshot() -> [AudioRouteDiagnosticsSnapshot] { [] }

    func performMaintenance() -> Bool { false }

    func shutdown(reason: AudioRouteStopReason) -> AudioRouteStopReport {
        shutdownReasons.append(reason)
        return AudioRouteStopReport(succeeded: true, errorMessage: nil)
    }
}
