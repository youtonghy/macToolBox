import Combine
import XCTest
@testable import ToolBoxCore

final class AudioRoutingServiceTests: XCTestCase {
    @MainActor
    func testTerminationShutdownRepliesAfterTimeout() async throws {
        let coordinator = TerminationShutdownCoordinator(timeout: .milliseconds(10))
        let reply = expectation(description: "termination reply")
        var replyCount = 0

        coordinator.start(
            shutdown: {
                try? await Task.sleep(for: .seconds(60))
            },
            reply: {
                replyCount += 1
                reply.fulfill()
            }
        )

        await fulfillment(of: [reply], timeout: 1)
        XCTAssertEqual(replyCount, 1)
    }

    @MainActor
    func testTerminationShutdownRepliesOnlyOnceWhenShutdownFinishes() async throws {
        let coordinator = TerminationShutdownCoordinator(timeout: .milliseconds(20))
        let reply = expectation(description: "termination reply")
        var replyCount = 0

        coordinator.start(
            shutdown: {},
            reply: {
                replyCount += 1
                reply.fulfill()
            }
        )

        await fulfillment(of: [reply], timeout: 1)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(replyCount, 1)
    }

    func testPendingTaskOwnershipRejectsStaleRelease() throws {
        var ownership = PendingTaskOwnership<String>()
        let staleOwner = try XCTUnwrap(ownership.claim("us.zoom.xos"))

        ownership.removeAll()
        let currentOwner = try XCTUnwrap(ownership.claim("us.zoom.xos"))

        XCTAssertFalse(ownership.release("us.zoom.xos", owner: staleOwner))
        XCTAssertTrue(ownership.release("us.zoom.xos", owner: currentOwner))
    }

    func testGainOnlyReconcileUsesRuntimeParameterUpdate() async {
        let native = FakeNativeAudioRouteEngine()
        let controller = AudioRouteController(nativeEngine: native)

        _ = await controller.reconcile(plans: [Self.plan(gain: 1)], generation: 1)
        let report = await controller.reconcile(plans: [Self.plan(gain: 3)], generation: 2)

        XCTAssertEqual(native.reconcileCalls.count, 1)
        XCTAssertEqual(
            native.parameterUpdates,
            [[AudioRouteNativeRuntimeParameters(routeID: "headset", sourceIndex: 0, targetGain: 3)]]
        )
        XCTAssertEqual(report.status, .applied)
    }

    func testTopologyChangeReconcilesOnlyAffectedRoute() async {
        let native = FakeNativeAudioRouteEngine()
        let controller = AudioRouteController(nativeEngine: native)

        let speakers = AudioRoutePlan(
            outputDeviceUID: "speakers",
            sources: [AudioRouteSource(bundleID: "com.apple.Music", processObjectID: 7, linearGain: 1)]
        )

        _ = await controller.reconcile(
            plans: [Self.plan(processObjectID: 42), speakers],
            generation: 1
        )
        _ = await controller.reconcile(
            plans: [Self.plan(processObjectID: 43), speakers],
            generation: 2
        )

        XCTAssertEqual(native.reconcileCalls.count, 2)
        XCTAssertEqual(native.reconcileCalls[1].changedPlans, [Self.plan(processObjectID: 43)])
        XCTAssertEqual(native.reconcileCalls[1].removingRouteIDs, ["headset"])
        XCTAssertEqual(native.parameterUpdates, [])
    }

    func testTopologyChangeBatchesFadeOutBeforeStoppingRoutes() async {
        let native = FakeNativeAudioRouteEngine()
        let controller = AudioRouteController(nativeEngine: native)
        let speakers = AudioRoutePlan(
            outputDeviceUID: "speakers",
            sources: [AudioRouteSource(bundleID: "com.apple.Music", processObjectID: 7, linearGain: 1)]
        )
        _ = await controller.reconcile(plans: [Self.plan(), speakers], generation: 1)

        _ = await controller.reconcile(plans: [], generation: 2)

        XCTAssertEqual(native.fadeOutCalls, [["headset", "speakers"]])
    }

    func testDeviceConfigurationGenerationForcesRouteRebuildForTheSameUID() async {
        let native = FakeNativeAudioRouteEngine()
        let controller = AudioRouteController(nativeEngine: native)
        let initial = Self.plan(deviceConfigurationGeneration: 1)
        let changed = Self.plan(deviceConfigurationGeneration: 2)

        _ = await controller.reconcile(plans: [initial], generation: 1)
        _ = await controller.reconcile(plans: [changed], generation: 2)

        XCTAssertEqual(native.reconcileCalls.count, 2)
        XCTAssertEqual(native.reconcileCalls[1].removingRouteIDs, ["headset"])
        XCTAssertEqual(native.reconcileCalls[1].changedPlans, [changed])
    }

    func testTopologyAndGainChangesAreAppliedInTheSameReconcile() async {
        let native = FakeNativeAudioRouteEngine()
        let controller = AudioRouteController(nativeEngine: native)
        let speakers = AudioRoutePlan(
            outputDeviceUID: "speakers",
            sources: [AudioRouteSource(bundleID: "com.apple.Music", processObjectID: 7, linearGain: 1)]
        )
        let louderSpeakers = AudioRoutePlan(
            outputDeviceUID: "speakers",
            sources: [AudioRouteSource(bundleID: "com.apple.Music", processObjectID: 7, linearGain: 2)]
        )
        _ = await controller.reconcile(plans: [Self.plan(), speakers], generation: 1)

        _ = await controller.reconcile(
            plans: [Self.plan(processObjectID: 43), louderSpeakers],
            generation: 2
        )

        XCTAssertEqual(
            native.reconcileCalls[1].retainedParameters,
            [AudioRouteNativeRuntimeParameters(routeID: "speakers", sourceIndex: 0, targetGain: 2)]
        )
    }

    func testOlderGenerationIsRejectedWithoutMutatingNativeEngine() async {
        let native = FakeNativeAudioRouteEngine()
        let controller = AudioRouteController(nativeEngine: native)

        _ = await controller.reconcile(plans: [Self.plan()], generation: 2)
        let stale = await controller.reconcile(plans: [], generation: 1)

        XCTAssertEqual(stale.status, .stale)
        XCTAssertEqual(native.reconcileCalls.count, 1)
    }

    func testCleanupFailureIsReportedAsBlocked() async {
        let native = FakeNativeAudioRouteEngine()
        native.reconcileError = TestError.applyFailed
        native.stopReport = AudioRouteStopReport(
            succeeded: false,
            errorMessage: "cleanup failed"
        )
        let controller = AudioRouteController(nativeEngine: native)

        let report = await controller.reconcile(plans: [Self.plan()], generation: 1)

        XCTAssertEqual(report.status, .cleanupBlocked("cleanup failed"))
        XCTAssertEqual(native.stopReasons, [.reconcileFailure])
    }

    func testCleanupBlockedLatchRejectsLaterReconcileWithoutCreatingAgain() async {
        let native = FakeNativeAudioRouteEngine()
        native.reconcileError = TestError.applyFailed
        native.stopReport = AudioRouteStopReport(succeeded: false, errorMessage: "cleanup failed")
        let controller = AudioRouteController(nativeEngine: native)

        _ = await controller.reconcile(plans: [Self.plan()], generation: 1)
        native.reconcileError = nil
        let blocked = await controller.reconcile(
            plans: [Self.plan(processObjectID: 43)],
            generation: 2
        )

        XCTAssertEqual(blocked.status, .cleanupBlocked("cleanup failed"))
        XCTAssertEqual(native.replaceAttemptCount, 1)
    }

    func testRecoveredRouteFailureKeepsPreviouslyAppliedRoutes() async {
        let native = FakeNativeAudioRouteEngine()
        let controller = AudioRouteController(nativeEngine: native)
        let original = Self.plan(processObjectID: 42)
        _ = await controller.reconcile(plans: [original], generation: 1)
        native.reconcileError = AudioRouteControllerError.routeApplyFailed("start failed; rolled back")

        let report = await controller.reconcile(
            plans: [Self.plan(processObjectID: 43)],
            generation: 2
        )

        XCTAssertEqual(report.status, .failed("start failed; rolled back"))
        XCTAssertEqual(report.plans, [original])
        XCTAssertEqual(native.stopReasons, [])
    }

    func testDuplicateRouteIdentifiersFailWithoutTrappingOrMutatingNativeEngine() async {
        let native = FakeNativeAudioRouteEngine()
        let controller = AudioRouteController(nativeEngine: native)

        let report = await controller.reconcile(
            plans: [Self.plan(processObjectID: 42), Self.plan(processObjectID: 43)],
            generation: 1
        )

        guard case .failed = report.status else {
            return XCTFail("Expected malformed plan failure")
        }
        XCTAssertEqual(native.replaceAttemptCount, 0)
    }

    func testAudioServerRestartUsesExplicitStopReason() async {
        let native = FakeNativeAudioRouteEngine()
        let controller = AudioRouteController(nativeEngine: native)

        let report = await controller.stopAll(reason: .audioServerRestarted)

        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(native.stopReasons, [.audioServerRestarted])
    }

    func testNormalStopAllBeginsOneBatchedFadeOut() async {
        let native = FakeNativeAudioRouteEngine()
        let controller = AudioRouteController(nativeEngine: native)

        _ = await controller.stopAll(reason: .serviceStopped)

        XCTAssertEqual(native.fadeOutAllCallCount, 1)
    }

    @available(macOS 14.2, *)
    func testNativeRollbackFailureForcesFullReset() throws {
        let engine = RollbackFailingAudioRouteEngine()
        let controller = NativeAudioRouteEngineController(engine: engine)
        let original = Self.plan(processObjectID: 42)
        try controller.reconcile(
            changedPlans: [original],
            removingRouteIDs: [],
            retainedParameters: []
        )
        engine.shouldFailStarts = true

        XCTAssertThrowsError(
            try controller.reconcile(
                changedPlans: [Self.plan(processObjectID: 43)],
                removingRouteIDs: [original.id],
                retainedParameters: []
            )
        ) { error in
            guard case AudioRouteControllerError.cleanupFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(engine.stopAllCallCount, 1)
    }

    @available(macOS 14.2, *)
    func testNativeStartFailureWithPendingCleanupDoesNotAttemptRollback() throws {
        let engine = CleanupPendingAudioRouteEngine()
        let controller = NativeAudioRouteEngineController(engine: engine)

        XCTAssertThrowsError(
            try controller.reconcile(
                changedPlans: [Self.plan(processObjectID: 42)],
                removingRouteIDs: [],
                retainedParameters: []
            )
        ) { error in
            guard case AudioRouteControllerError.cleanupFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(engine.startCallCount, 1)
    }

    @MainActor
    func testStaleRestartHandlerCannotUnlockCurrentSession() async throws {
        let suiteName = "test.audioRoutingService.restartOwnership.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let processRegistry = FakeAudioProcessRegistry(snapshot: [])
        let deviceRegistry = FakeAudioDeviceRegistry(snapshot: [], defaultOutputUID: nil)
        let engine = BlockingRestartAudioRouteEngine()
        let service = AudioRoutingService(
            ruleStore: AudioRuleStore(defaults: defaults, key: suiteName),
            processRegistry: processRegistry,
            deviceRegistry: deviceRegistry,
            engine: engine
        )

        service.start()
        deviceRegistry.publishServiceGeneration(1)
        await engine.waitUntilRestartStopCount(1)

        service.stop()
        service.start()
        deviceRegistry.publishServiceGeneration(2)
        await engine.waitUntilRestartStopCount(2)

        await engine.releaseRestartStop(number: 1)
        await Task.yield()
        await Task.yield()
        deviceRegistry.publishServiceGeneration(3)
        try await Task.sleep(for: .milliseconds(30))

        let restartStopCount = await engine.restartStopCount()
        XCTAssertEqual(restartStopCount, 2)

        await engine.releaseAllRestartStops()
        _ = await service.shutdown()
    }

    @MainActor
    func testAudioServerRestartBlocksRuntimeGainUpdates() async throws {
        let suiteName = "test.audioRoutingService.restartRuntimeGain.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AudioRuleStore(defaults: defaults, key: suiteName)
        try store.save([AppAudioRule(bundleID: "us.zoom.xos", volumePercent: 150)])

        let processRegistry = FakeAudioProcessRegistry(snapshot: [
            AudioProcessSnapshot(
                objectID: 42,
                pid: 1234,
                bundleID: "us.zoom.xos",
                name: "zoom.us",
                isRunningOutput: true
            )
        ])
        let deviceRegistry = FakeAudioDeviceRegistry(
            snapshot: [AudioOutputDevice(uid: "speakers", name: "Speakers", isAvailable: true)],
            defaultOutputUID: "speakers"
        )
        let engine = WatchdogAudioRouteEngine()
        let service = AudioRoutingService(
            ruleStore: store,
            processRegistry: processRegistry,
            deviceRegistry: deviceRegistry,
            engine: engine
        )

        service.start()
        await engine.waitUntilReconcileCount(1)
        await engine.blockNextStop()
        deviceRegistry.publishServiceGeneration(1)
        await engine.waitUntilStopCount(1)

        service.setVolume(bundleID: "us.zoom.xos", percent: 200)
        try await Task.sleep(for: .milliseconds(30))

        let updateCount = await engine.updateCount()
        XCTAssertEqual(updateCount, 0)

        await engine.releaseStop()
        _ = await service.shutdown()
    }

    @MainActor
    func testAudioServerRestartRefreshPerformsSingleReconcile() async throws {
        let suiteName = "test.audioRoutingService.restartRefresh.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AudioRuleStore(defaults: defaults, key: suiteName)
        try store.save([AppAudioRule(bundleID: "us.zoom.xos", volumePercent: 150)])

        let original = AudioProcessSnapshot(
            objectID: 42,
            pid: 1234,
            bundleID: "us.zoom.xos",
            name: "zoom.us",
            isRunningOutput: true
        )
        let refreshed = AudioProcessSnapshot(
            objectID: 43,
            pid: 1234,
            bundleID: "us.zoom.xos",
            name: "zoom.us",
            isRunningOutput: true
        )
        let processRegistry = FakeAudioProcessRegistry(
            snapshot: [original],
            restartSnapshot: [refreshed]
        )
        let deviceRegistry = FakeAudioDeviceRegistry(
            snapshot: [AudioOutputDevice(uid: "speakers", name: "Speakers", isAvailable: true)],
            defaultOutputUID: "speakers"
        )
        let engine = WatchdogAudioRouteEngine()
        let service = AudioRoutingService(
            ruleStore: store,
            processRegistry: processRegistry,
            deviceRegistry: deviceRegistry,
            engine: engine
        )

        service.start()
        await engine.waitUntilReconcileCount(1)
        deviceRegistry.publishServiceGeneration(1)
        await engine.waitUntilReconcileCount(2)
        try await Task.sleep(for: .milliseconds(30))

        let reconcileCount = await engine.reconcileCount()
        XCTAssertEqual(reconcileCount, 2)
        _ = await service.shutdown()
    }

    func testRuntimeUpdateUsesStableProcessIdentityAndRejectsStaleGeneration() async {
        let native = FakeNativeAudioRouteEngine()
        let controller = AudioRouteController(nativeEngine: native)
        _ = await controller.reconcile(plans: [Self.plan()], generation: 2)

        let stale = await controller.update(parameters: [
            AudioRouteRuntimeParameters(
                generation: 1,
                routeID: "headset",
                processObjectID: 42,
                targetGain: 2
            )
        ])
        let current = await controller.update(parameters: [
            AudioRouteRuntimeParameters(
                generation: 2,
                routeID: "headset",
                processObjectID: 42,
                targetGain: 2
            )
        ])

        XCTAssertEqual(stale.status, .stale)
        XCTAssertEqual(current.status, .applied)
        XCTAssertEqual(
            native.parameterUpdates,
            [[AudioRouteNativeRuntimeParameters(routeID: "headset", sourceIndex: 0, targetGain: 2)]]
        )
    }

    func testRuntimeUpdateAdvancesToANewerDesiredGeneration() async {
        let native = FakeNativeAudioRouteEngine()
        let controller = AudioRouteController(nativeEngine: native)
        _ = await controller.reconcile(plans: [Self.plan()], generation: 1)

        let report = await controller.update(parameters: [
            AudioRouteRuntimeParameters(
                generation: 2,
                routeID: "headset",
                processObjectID: 42,
                targetGain: 2.5
            )
        ])

        XCTAssertEqual(report.status, .applied)
        XCTAssertEqual(report.generation, 2)
        XCTAssertEqual(report.plans.first?.sources.first?.linearGain, 2.5)
    }

    @MainActor
    func testLateEngineResultCannotOverwriteNewerServiceGeneration() async throws {
        let suiteName = "test.audioRoutingService.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AudioRuleStore(defaults: defaults, key: suiteName)
        try store.save([AppAudioRule(bundleID: "us.zoom.xos", volumePercent: 200)])

        let processRegistry = FakeAudioProcessRegistry(
            snapshot: [
                AudioProcessSnapshot(
                    objectID: 42,
                    pid: 1234,
                    bundleID: "us.zoom.xos",
                    name: "zoom.us",
                    isRunningOutput: true
                )
            ]
        )
        let deviceRegistry = FakeAudioDeviceRegistry(
            snapshot: [AudioOutputDevice(uid: "speakers", name: "Speakers", isAvailable: true)],
            defaultOutputUID: "speakers"
        )
        let engine = ScriptedAudioRouteEngine(blockedGeneration: 1)
        let service = AudioRoutingService(
            ruleStore: store,
            processRegistry: processRegistry,
            deviceRegistry: deviceRegistry,
            engine: engine
        )

        service.start()
        await engine.waitUntilObserved(generation: 1)
        deviceRegistry.publishDefaultOutputUID(nil)
        await engine.waitUntilObserved(generation: 2)
        await Task.yield()

        guard case let .failed(message) = try XCTUnwrap(service.rows.first).state else {
            return XCTFail("Expected missing-default failure from generation 2")
        }
        XCTAssertEqual(message, "系统默认输出设备不可用")

        await engine.releaseBlockedGeneration()
        await Task.yield()

        guard case let .failed(finalMessage) = try XCTUnwrap(service.rows.first).state else {
            return XCTFail("Late generation 1 result replaced generation 2")
        }
        XCTAssertEqual(finalMessage, "系统默认输出设备不可用")
        _ = await service.shutdown()
    }

    @MainActor
    func testServiceShowsRouteWithAudioFramesWhenHALOutputFlagIsOff() async throws {
        let harness = try makeServiceHarness(volumePercent: 200, isRunningOutput: true)
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)
        try XCTUnwrap(harness.processRegistry).setSnapshot([
            AudioProcessSnapshot(
                objectID: 42,
                pid: 1234,
                bundleID: "us.zoom.xos",
                name: "zoom.us",
                isRunningOutput: false
            )
        ])
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(try XCTUnwrap(harness.service.rows.first).state, .starting)

        await harness.engine.setDiagnostics([
            AudioRouteDiagnosticsSnapshot(
                routeID: "speakers",
                generation: 1,
                captureCallbackCount: 1,
                captureFrameCount: 512,
                outputCallbackCount: 1,
                outputFrameCount: 512
            )
        ])
        await harness.service.runDiagnosticsWatchdogTick()

        XCTAssertEqual(try XCTUnwrap(harness.service.rows.first).state, .active)
        XCTAssertEqual(harness.service.playingRows.map(\.bundleID), ["us.zoom.xos"])
        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    @MainActor
    func testBluetoothProfileTransitionSuspendsAndRestoresRouteOnlyOncePerStableSnapshot() async throws {
        let suiteName = "test.audioRoutingService.bluetooth.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AudioRuleStore(defaults: defaults, key: suiteName)
        try store.save([AppAudioRule(bundleID: "us.zoom.xos", volumePercent: 150)])
        let processRegistry = FakeAudioProcessRegistry(
            snapshot: [
                AudioProcessSnapshot(
                    objectID: 42,
                    pid: 1234,
                    bundleID: "us.zoom.xos",
                    name: "zoom.us",
                    isRunningOutput: true
                )
            ]
        )
        let compatible = AudioOutputDevice(
            uid: "bluetooth-headset",
            name: "Bluetooth Headset",
            isAvailable: true,
            sampleRate: 44_100
        )
        let incompatible = AudioOutputDevice(
            uid: compatible.uid,
            name: compatible.name,
            isAvailable: true,
            compatibilityIssue: .requiresInterleavedStereo,
            sampleRate: 16_000
        )
        let deviceRegistry = FakeAudioDeviceRegistry(
            snapshot: [compatible],
            defaultOutputUID: compatible.uid
        )
        let engine = WatchdogAudioRouteEngine()
        let service = AudioRoutingService(
            ruleStore: store,
            processRegistry: processRegistry,
            deviceRegistry: deviceRegistry,
            engine: engine
        )

        service.start()
        await engine.waitUntilReconcileCount(1)

        deviceRegistry.publishSnapshot([incompatible])
        await engine.waitUntilReconcileCount(2)
        let suspendedPlans = await engine.currentPlans()
        XCTAssertTrue(suspendedPlans.isEmpty)

        deviceRegistry.publishSnapshot([incompatible])
        try await Task.sleep(for: .milliseconds(30))
        let countDuringDuplicateNotifications = await engine.reconcileCount()
        XCTAssertEqual(countDuringDuplicateNotifications, 2)

        deviceRegistry.publishSnapshot([compatible])
        await engine.waitUntilReconcileCount(3)
        let restoredPlans = await engine.currentPlans()
        XCTAssertEqual(restoredPlans.map(\.id), [compatible.uid])

        _ = await service.shutdown()
    }

    @MainActor
    func testFatalDiagnosticsStopRouteWithinOneWatchdogTick() async throws {
        let harness = try makeServiceHarness(volumePercent: 200)
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)
        await harness.engine.setDiagnostics([
            AudioRouteDiagnosticsSnapshot(
                routeID: "speakers",
                generation: 1,
                formatMismatchCount: 1,
                fatalCallbackMismatch: true
            )
        ])

        await harness.service.runDiagnosticsWatchdogTick()

        await harness.engine.waitUntilReconcileCount(2)
        let remainingPlans = await harness.engine.currentPlans()
        XCTAssertEqual(remainingPlans, [])
        guard case .failed = try XCTUnwrap(harness.service.rows.first).state else {
            return XCTFail("Expected fatal callback diagnostics to fail the route")
        }
        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    @MainActor
    func testFatalDiagnosticsStopOnlyTheAffectedOutputRoute() async throws {
        let harness = try makeTwoRouteServiceHarness()
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)
        await harness.engine.setDiagnostics([
            AudioRouteDiagnosticsSnapshot(
                routeID: "speakers",
                generation: 1,
                captureCallbackCount: 1,
                captureFrameCount: 512,
                outputCallbackCount: 1,
                outputFrameCount: 512
            ),
            AudioRouteDiagnosticsSnapshot(
                routeID: "headset",
                generation: 1,
                formatMismatchCount: 1,
                fatalCallbackMismatch: true
            )
        ])

        await harness.service.runDiagnosticsWatchdogTick()
        await harness.engine.waitUntilReconcileCount(2)

        let remainingRouteIDs = (await harness.engine.currentPlans()).map(\.id)
        XCTAssertEqual(remainingRouteIDs, ["speakers"])
        XCTAssertEqual(
            harness.service.rows.first(where: { $0.bundleID == "com.apple.Music" })?.state,
            .active
        )
        guard case .failed = try XCTUnwrap(
            harness.service.rows.first(where: { $0.bundleID == "us.zoom.xos" })?.state
        ) else {
            return XCTFail("Expected only the failed output route to be released")
        }
        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    @MainActor
    func testRuntimeGainSurvivesUnrelatedFatalRouteRemoval() async throws {
        let harness = try makeTwoRouteServiceHarness()
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)

        harness.service.setVolume(bundleID: "com.apple.Music", percent: 250)
        await harness.engine.waitUntilUpdateCount(1)

        await harness.engine.setDiagnostics([
            AudioRouteDiagnosticsSnapshot(
                routeID: "speakers",
                generation: 1,
                captureCallbackCount: 1,
                captureFrameCount: 512,
                outputCallbackCount: 1,
                outputFrameCount: 512
            ),
            AudioRouteDiagnosticsSnapshot(
                routeID: "headset",
                generation: 1,
                formatMismatchCount: 1,
                fatalCallbackMismatch: true
            )
        ])

        await harness.service.runDiagnosticsWatchdogTick()
        await harness.engine.waitUntilReconcileCount(2)

        let currentPlans = await harness.engine.currentPlans()
        let speakers = try XCTUnwrap(currentPlans.first(where: { $0.id == "speakers" }))
        let music = try XCTUnwrap(
            speakers.sources.first(where: { $0.bundleID == "com.apple.Music" })
        )
        XCTAssertEqual(music.linearGain, 2.5, accuracy: 0.001)
        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    @MainActor
    func testOutputDeviceSelectionImmediatelyReconcilesWithoutRegistrySettleDelay() async throws {
        let harness = try makeTwoRouteServiceHarness()
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)

        harness.service.setOutputDevice(bundleID: "com.apple.Music", uid: "headset")
        await harness.engine.waitUntilReconcileCount(2)

        let currentPlans = await harness.engine.currentPlans()
        XCTAssertEqual(currentPlans.map(\.id), ["headset"])
        XCTAssertEqual(
            currentPlans.first?.sources.map(\.bundleID).sorted(),
            ["com.apple.Music", "us.zoom.xos"]
        )
        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    @MainActor
    func testNoCallbacksBecomeHonestAwaitingAudioState() async throws {
        let harness = try makeServiceHarness(volumePercent: 200)
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)

        for _ in 0..<AudioRouteDiagnosticsEvaluator.startupGracePollCount {
            await harness.service.runDiagnosticsWatchdogTick()
        }

        guard case let .awaitingAudio(message) = try XCTUnwrap(harness.service.rows.first).state else {
            return XCTFail("Expected awaiting-audio state")
        }
        XCTAssertEqual(message, "权限、受保护内容或当前无可捕获音频")
        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    @MainActor
    func testPausedPlaybackKeepsRouteAndSavedGain() async throws {
        let harness = try makeServiceHarness(volumePercent: 150)
        let processRegistry = try XCTUnwrap(harness.processRegistry)
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)

        // Playback pauses: HAL drops `piro`, the output IOProc keeps running.
        processRegistry.setSnapshot([
            AudioProcessSnapshot(
                objectID: 42,
                pid: 1234,
                bundleID: "us.zoom.xos",
                name: "zoom.us",
                isRunningOutput: false
            )
        ])
        try await Task.sleep(for: .milliseconds(20))

        var outputFrames: UInt64 = 512
        for _ in 0...(AudioRouteDiagnosticsEvaluator.stallPollCount + 2) {
            await harness.engine.setDiagnostics([
                AudioRouteDiagnosticsSnapshot(
                    routeID: "speakers",
                    generation: 1,
                    captureCallbackCount: 1,
                    captureFrameCount: 512,
                    outputCallbackCount: 1,
                    outputFrameCount: outputFrames
                )
            ])
            await harness.service.runDiagnosticsWatchdogTick()
            outputFrames += 512
        }

        let plans = await harness.engine.currentPlans()
        let reconcileCount = await harness.engine.reconcileCount()
        XCTAssertEqual(reconcileCount, 1)
        XCTAssertEqual(plans.first?.sources.first?.linearGain, 1.5)
        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    @MainActor
    func testResumedProcessRestoresSavedGainAfterStalledRouteWasReleased() async throws {
        let harness = try makeServiceHarness(volumePercent: 150)
        let processRegistry = try XCTUnwrap(harness.processRegistry)
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)

        processRegistry.setSnapshot([
            AudioProcessSnapshot(
                objectID: 42,
                pid: 1234,
                bundleID: "us.zoom.xos",
                name: "zoom.us",
                isRunningOutput: false
            )
        ])
        try await Task.sleep(for: .milliseconds(20))

        let stalledDiagnostics = [
            AudioRouteDiagnosticsSnapshot(
                routeID: "speakers",
                generation: 1,
                captureCallbackCount: 1,
                captureFrameCount: 512,
                outputCallbackCount: 1,
                outputFrameCount: 512
            )
        ]
        await harness.engine.setDiagnostics(stalledDiagnostics)
        await harness.service.runDiagnosticsWatchdogTick()
        for _ in 0..<AudioRouteDiagnosticsEvaluator.stallPollCount {
            await harness.service.runDiagnosticsWatchdogTick()
        }
        await harness.engine.waitUntilReconcileCount(2)
        let releasedPlans = await harness.engine.currentPlans()
        XCTAssertTrue(releasedPlans.isEmpty)

        processRegistry.setSnapshot([
            AudioProcessSnapshot(
                objectID: 42,
                pid: 1234,
                bundleID: "us.zoom.xos",
                name: "zoom.us",
                isRunningOutput: true
            )
        ])
        try await Task.sleep(for: .milliseconds(50))

        let restoredPlans = await harness.engine.currentPlans()
        let reconcileCount = await harness.engine.reconcileCount()
        XCTAssertEqual(reconcileCount, 3)
        XCTAssertEqual(restoredPlans.first?.sources.first?.linearGain, 1.5)
        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    @MainActor
    func testFastRestartWaitsForPreviousStopBeforeReconcilingAgain() async throws {
        let harness = try makeServiceHarness(volumePercent: 200)
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)
        await harness.engine.blockNextStop()

        harness.service.stop()
        harness.service.start()
        await Task.yield()
        await Task.yield()
        let countWhileStopping = await harness.engine.reconcileCount()
        XCTAssertEqual(countWhileStopping, 1)

        await harness.engine.releaseStop()
        await harness.engine.waitUntilReconcileCount(2)
        let countAfterRestart = await harness.engine.reconcileCount()
        XCTAssertEqual(countAfterRestart, 2)
        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    @MainActor
    func testStoppedServiceRejectsLateReconcile() async throws {
        let harness = try makeServiceHarness(volumePercent: 200)
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)

        harness.service.stop()
        await harness.service.reconcile(
            processes: try XCTUnwrap(harness.processRegistry).snapshot,
            devices: [AudioOutputDevice(uid: "speakers", name: "Speakers", isAvailable: true)],
            defaultOutputUID: "speakers"
        )

        let reconcileCount = await harness.engine.reconcileCount()
        XCTAssertEqual(reconcileCount, 1, "A late task must not restore routes after stop")
        XCTAssertTrue(harness.service.rows.isEmpty)
        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    @MainActor
    func testShutdownInvalidatesSessionBeforeAwaitingEngineStop() async throws {
        let harness = try makeServiceHarness(volumePercent: 200)
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)
        await harness.engine.blockNextStop()

        let shutdownTask = Task { await harness.service.shutdown() }
        await harness.engine.waitUntilStopCount(1)

        let processes = try XCTUnwrap(harness.processRegistry).snapshot
        await harness.service.reconcile(
            processes: processes,
            devices: [AudioOutputDevice(uid: "speakers", name: "Speakers", isAvailable: true)],
            defaultOutputUID: "speakers"
        )
        await harness.engine.releaseStop()
        let report = await shutdownTask.value

        await harness.service.reconcile(
            processes: processes,
            devices: [AudioOutputDevice(uid: "speakers", name: "Speakers", isAvailable: true)],
            defaultOutputUID: "speakers"
        )

        let reconcileCount = await harness.engine.reconcileCount()
        let currentPlans = await harness.engine.currentPlans()
        let stopReasons = await harness.engine.stopReasons()
        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(reconcileCount, 1)
        XCTAssertTrue(currentPlans.isEmpty)
        XCTAssertEqual(stopReasons, [.serviceStopped])
        harness.cleanup()
    }

    @MainActor
    func testShutdownIsIdempotentUntilServiceRestarts() async throws {
        let harness = try makeServiceHarness(volumePercent: 200)
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)

        let firstReport = await harness.service.shutdown()
        let secondReport = await harness.service.shutdown()
        let reasonsBeforeRestart = await harness.engine.stopReasons()

        XCTAssertEqual(firstReport, secondReport)
        XCTAssertEqual(reasonsBeforeRestart, [.serviceStopped])

        harness.service.start()
        await harness.engine.waitUntilReconcileCount(2)
        _ = await harness.service.shutdown()
        let reasonsAfterRestart = await harness.engine.stopReasons()
        XCTAssertEqual(reasonsAfterRestart, [.serviceStopped, .serviceStopped])
        harness.cleanup()
    }

    @MainActor
    func testRolledBackTopologyRemainsAvailableForRuntimeGainUpdate() async throws {
        let harness = try makeServiceHarness(volumePercent: 200)
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)
        await harness.engine.failNextReconcileKeepingCurrentPlans(message: "start failed; rolled back")

        try XCTUnwrap(harness.processRegistry).setSnapshot([
            AudioProcessSnapshot(
                objectID: 43,
                pid: 1234,
                bundleID: "us.zoom.xos",
                name: "zoom.us",
                isRunningOutput: true
            )
        ])
        await harness.engine.waitUntilReconcileCount(2)

        harness.service.setVolume(bundleID: "us.zoom.xos", percent: 250)
        try await Task.sleep(for: .milliseconds(50))

        let reconcileCount = await harness.engine.reconcileCount()
        let updateCount = await harness.engine.updateCount()
        let updatedProcessObjectIDs = await harness.engine.lastUpdate()?.map(\.processObjectID)
        XCTAssertEqual(reconcileCount, 2)
        XCTAssertEqual(updateCount, 1)
        XCTAssertEqual(updatedProcessObjectIDs, [42])
        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    @MainActor
    func testRolledBackTopologyDoesNotMarkReplacementProcessActive() async throws {
        let harness = try makeServiceHarness(volumePercent: 200)
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)
        await harness.engine.failNextReconcileKeepingCurrentPlans(message: "start failed; rolled back")

        try XCTUnwrap(harness.processRegistry).setSnapshot([
            AudioProcessSnapshot(
                objectID: 43,
                pid: 1234,
                bundleID: "us.zoom.xos",
                name: "zoom.us",
                isRunningOutput: true
            )
        ])
        await harness.engine.waitUntilReconcileCount(2)
        await harness.engine.setDiagnostics([
            AudioRouteDiagnosticsSnapshot(
                routeID: "speakers",
                generation: 2,
                captureCallbackCount: 1,
                captureFrameCount: 512,
                outputCallbackCount: 1,
                outputFrameCount: 512
            )
        ])

        await harness.service.runDiagnosticsWatchdogTick()

        guard case .failed = try XCTUnwrap(harness.service.rows.first).state else {
            return XCTFail("The replacement process must retain the failed desired-route state")
        }
        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    @MainActor
    func testCleanupBlockedRestartsWatchdogForEffectivePlans() async throws {
        let harness = try makeServiceHarness(volumePercent: 200)
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)
        await harness.engine.cleanupBlockNextReconcileKeepingCurrentPlans(message: "cleanup failed")

        try XCTUnwrap(harness.processRegistry).setSnapshot([
            AudioProcessSnapshot(
                objectID: 43,
                pid: 1234,
                bundleID: "us.zoom.xos",
                name: "zoom.us",
                isRunningOutput: true
            )
        ])
        await harness.engine.waitUntilReconcileCount(2)
        await harness.engine.setDiagnostics([
            AudioRouteDiagnosticsSnapshot(
                routeID: "speakers",
                generation: 2,
                formatMismatchCount: 1,
                fatalCallbackMismatch: true
            )
        ])

        await harness.service.runDiagnosticsWatchdogTick()

        let reconcileCount = await harness.engine.reconcileCount()
        XCTAssertEqual(reconcileCount, 3, "The current watchdog must process the retained route")
        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    @MainActor
    func testVolumeSliderUsesRuntimeUpdateWhenTopologyAlreadyExists() async throws {
        let harness = try makeServiceHarness(volumePercent: 150)
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)

        harness.service.setVolume(bundleID: "us.zoom.xos", percent: 200)
        await harness.engine.waitUntilUpdateCount(1)

        let reconcileCount = await harness.engine.reconcileCount()
        XCTAssertEqual(reconcileCount, 1)
        let parameters = await harness.engine.lastUpdate()
        XCTAssertEqual(parameters?.map(\.targetGain), [2])
        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    @MainActor
    func testRapidVolumeChangesApplyOnlyLatestValuePerFrame() async throws {
        let harness = try makeServiceHarness(volumePercent: 150)
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)

        harness.service.setVolume(bundleID: "us.zoom.xos", percent: 160)
        harness.service.setVolume(bundleID: "us.zoom.xos", percent: 170)
        harness.service.setVolume(bundleID: "us.zoom.xos", percent: 180)

        XCTAssertEqual(try XCTUnwrap(harness.service.rows.first).volumePercent, 180)
        await harness.engine.waitUntilUpdateCount(1)
        try await Task.sleep(for: .milliseconds(30))

        let updateCount = await harness.engine.updateCount()
        let lastTargets = await harness.engine.lastUpdate()?.map(\.targetGain)
        XCTAssertEqual(updateCount, 1)
        XCTAssertEqual(lastTargets, [1.8])
        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    @MainActor
    func testSavedRuleRemainsVisibleWhenHALPlaybackFlagIsOff() async throws {
        let harness = try makeServiceHarness(volumePercent: 100, isRunningOutput: false)
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)

        XCTAssertEqual(harness.service.playingRows.map(\.bundleID), ["us.zoom.xos"])
        XCTAssertTrue(
            harness.service.menuRows.isEmpty,
            "Saved-but-idle rules belong in Settings, not the menu mixer"
        )
        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    @MainActor
    func testIsRunningFlagAloneKeepsAppVisibleWithoutIsRunningOutput() async throws {
        let harness = try makeServiceHarness(
            volumePercent: 100,
            isRunningOutput: false,
            isRunning: true,
            hasSavedRule: false
        )
        harness.service.start()
        await Task.yield()

        XCTAssertEqual(harness.service.playingRows.map(\.bundleID), ["us.zoom.xos"])
        XCTAssertTrue(try XCTUnwrap(harness.service.playingRows.first).isRunning)
        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    @MainActor
    func testRecentlyActiveKeepsAppVisibleAfterHALDrops() async throws {
        let clock = TestClock(start: Date(timeIntervalSince1970: 5_000))
        let harness = try makeServiceHarness(
            volumePercent: 100,
            isRunningOutput: true,
            isRunning: false,
            hasSavedRule: false,
            recentlyActiveWindow: 12,
            now: { clock.now }
        )
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)
        XCTAssertEqual(harness.service.playingRows.map(\.bundleID), ["us.zoom.xos"])

        let silentSnapshot = [
            AudioProcessSnapshot(
                objectID: 42,
                pid: 1234,
                bundleID: "us.zoom.xos",
                name: "zoom.us",
                isRunningOutput: false,
                isRunning: false
            )
        ]
        try XCTUnwrap(harness.processRegistry).setSnapshot(silentSnapshot)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(
            harness.service.playingRows.map(\.bundleID),
            ["us.zoom.xos"],
            "App should remain visible inside recently-active window"
        )

        clock.advance(by: 13)
        harness.service.refreshRecentlyActiveVisibility()
        XCTAssertTrue(harness.service.playingRows.isEmpty)

        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    @MainActor
    func testRecentlyActiveExpiresWithoutAnotherRegistryEvent() async throws {
        let harness = try makeServiceHarness(
            volumePercent: 100,
            isRunningOutput: true,
            hasSavedRule: false,
            recentlyActiveWindow: 0.03
        )
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)

        try XCTUnwrap(harness.processRegistry).setSnapshot([
            AudioProcessSnapshot(
                objectID: 42,
                pid: 1234,
                bundleID: "us.zoom.xos",
                name: "zoom.us",
                isRunningOutput: false
            )
        ])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(harness.service.playingRows.map(\.bundleID), ["us.zoom.xos"])

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(harness.service.playingRows.isEmpty)
        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    @MainActor
    func testActivityOnlyProcessUpdateDoesNotReconcileAudioRoutes() async throws {
        let harness = try makeServiceHarness(
            volumePercent: 200,
            isRunningOutput: false,
            isRunning: false
        )
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)

        try XCTUnwrap(harness.processRegistry).setSnapshot([
            AudioProcessSnapshot(
                objectID: 42,
                pid: 1234,
                bundleID: "us.zoom.xos",
                name: "zoom.us",
                isRunningOutput: false,
                isRunning: true
            )
        ])
        try await Task.sleep(for: .milliseconds(30))

        let reconcileCount = await harness.engine.reconcileCount()
        XCTAssertEqual(
            reconcileCount,
            1,
            "HAL activity changes must update visibility without restarting an unchanged route"
        )
        XCTAssertTrue(try XCTUnwrap(harness.service.rows.first).isRunning)
        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    @MainActor
    func testInFlightReconcileCannotOverwriteNewerActivityFlags() async throws {
        let suiteName = "test.audioRoutingService.activityRace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AudioRuleStore(defaults: defaults, key: suiteName)
        try store.save([AppAudioRule(bundleID: "us.zoom.xos", volumePercent: 200)])
        let processRegistry = FakeAudioProcessRegistry(
            snapshot: [
                AudioProcessSnapshot(
                    objectID: 42,
                    pid: 1234,
                    bundleID: "us.zoom.xos",
                    name: "zoom.us",
                    isRunningOutput: false
                )
            ]
        )
        let engine = ScriptedAudioRouteEngine(blockedGeneration: 1)
        let service = AudioRoutingService(
            ruleStore: store,
            processRegistry: processRegistry,
            deviceRegistry: FakeAudioDeviceRegistry(
                snapshot: [AudioOutputDevice(uid: "speakers", name: "Speakers", isAvailable: true)],
                defaultOutputUID: "speakers"
            ),
            engine: engine
        )

        service.start()
        await engine.waitUntilObserved(generation: 1)
        processRegistry.setSnapshot([
            AudioProcessSnapshot(
                objectID: 42,
                pid: 1234,
                bundleID: "us.zoom.xos",
                name: "zoom.us",
                isRunningOutput: true
            )
        ])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(try XCTUnwrap(service.rows.first).isRunning)

        await engine.releaseBlockedGeneration()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(
            try XCTUnwrap(service.rows.first).isRunning,
            "A slow route apply must not restore stale HAL activity flags"
        )
        _ = await service.shutdown()
    }

    @MainActor
    func testSettingsRowsSortCurrentlyPlayingBeforeConfiguredIdle() async throws {
        let harness = try makeStableOrderServiceHarness()
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)

        // Zulu is the only player initially; Alpha is idle with a saved rule.
        XCTAssertEqual(
            harness.service.playingRows.map(\.bundleID),
            ["com.example.zulu", "com.example.alpha"]
        )
        XCTAssertEqual(
            harness.service.menuRows.map(\.bundleID),
            ["com.example.zulu"]
        )

        try XCTUnwrap(harness.processRegistry).setSnapshot([
            AudioProcessSnapshot(
                objectID: 1,
                pid: 101,
                bundleID: "com.example.alpha",
                name: "Alpha",
                isRunningOutput: true
            ),
            AudioProcessSnapshot(
                objectID: 2,
                pid: 102,
                bundleID: "com.example.zulu",
                name: "Zulu",
                isRunningOutput: false
            )
        ])
        await Task.yield()
        await Task.yield()

        // Alpha is HAL-active; Zulu stays menu-visible briefly via recently-active.
        XCTAssertEqual(
            harness.service.playingRows.map(\.bundleID),
            ["com.example.alpha", "com.example.zulu"]
        )
        XCTAssertEqual(
            harness.service.menuRows.map(\.bundleID),
            ["com.example.alpha", "com.example.zulu"]
        )
        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    @MainActor
    func testVolumeChangeWaitsForExistingSilentProcessToProduceOutput() async throws {
        let harness = try makeServiceHarness(volumePercent: 100, isRunningOutput: false)
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)

        harness.service.setVolume(bundleID: "us.zoom.xos", percent: 200)
        await harness.engine.waitUntilReconcileCount(2)

        let plans = await harness.engine.currentPlans()
        XCTAssertTrue(plans.isEmpty)
        XCTAssertEqual(try XCTUnwrap(harness.service.rows.first).state, .waitingForProcess)
        XCTAssertEqual(harness.service.playingRows.map(\.bundleID), ["us.zoom.xos"])

        try XCTUnwrap(harness.processRegistry).setSnapshot([
            AudioProcessSnapshot(
                objectID: 42,
                pid: 1234,
                bundleID: "us.zoom.xos",
                name: "zoom.us",
                isRunningOutput: true
            )
        ])
        try await Task.sleep(for: .milliseconds(30))
        await harness.engine.waitUntilReconcileCount(3)

        let restoredPlans = await harness.engine.currentPlans()
        XCTAssertEqual(restoredPlans.first?.sources.first?.linearGain, 2)
        XCTAssertEqual(try XCTUnwrap(harness.service.rows.first).state, .starting)
        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    @MainActor
    func testStaleRuntimeUpdateFallsBackToFullReconcile() async throws {
        let harness = try makeServiceHarness(volumePercent: 150)
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)
        await harness.engine.rejectNextRuntimeUpdateAsStale()

        harness.service.setVolume(bundleID: "us.zoom.xos", percent: 200)
        await harness.engine.waitUntilUpdateCount(1)
        await harness.engine.waitUntilReconcileCount(2)

        let plans = await harness.engine.currentPlans()
        XCTAssertEqual(plans.first?.sources.first?.linearGain, 2)
        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    @MainActor
    func testVolumePersistenceCoalescesRapidSliderChanges() async throws {
        let harness = try makeServiceHarness(
            volumePercent: 150,
            persistenceDelay: .milliseconds(40)
        )
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)

        harness.service.setVolume(bundleID: "us.zoom.xos", percent: 160)
        harness.service.setVolume(bundleID: "us.zoom.xos", percent: 170)
        harness.service.setVolume(bundleID: "us.zoom.xos", percent: 180)

        XCTAssertEqual(harness.store.load().rules.first?.volumePercent, 150)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(harness.store.load().rules.first?.volumePercent, 180)

        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    @MainActor
    func testStoppingServiceFlushesPendingVolumePersistence() async throws {
        let harness = try makeServiceHarness(
            volumePercent: 150,
            persistenceDelay: .seconds(10)
        )
        harness.service.start()
        await harness.engine.waitUntilReconcileCount(1)

        harness.service.setVolume(bundleID: "us.zoom.xos", percent: 225)
        harness.service.stop()

        XCTAssertEqual(harness.store.load().rules.first?.volumePercent, 225)
        _ = await harness.service.shutdown()
        harness.cleanup()
    }

    private static func plan(
        processObjectID: UInt32 = 42,
        gain: Float = 1,
        deviceConfigurationGeneration: Int = 0
    ) -> AudioRoutePlan {
        AudioRoutePlan(
            outputDeviceUID: "headset",
            deviceConfigurationGeneration: deviceConfigurationGeneration,
            sources: [
                AudioRouteSource(
                    bundleID: "us.zoom.xos",
                    processObjectID: processObjectID,
                    linearGain: gain
                )
            ]
        )
    }

    @MainActor
    private func makeServiceHarness(
        volumePercent: Int,
        isRunningOutput: Bool = true,
        isRunning: Bool = false,
        hasSavedRule: Bool = true,
        persistenceDelay: Duration = .milliseconds(200),
        recentlyActiveWindow: TimeInterval = AudioAppListVisibility.recentlyActiveWindow,
        now: @escaping () -> Date = Date.init
    ) throws -> ServiceHarness {
        let suiteName = "test.audioRoutingService.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = AudioRuleStore(defaults: defaults, key: suiteName)
        if hasSavedRule {
            try store.save([AppAudioRule(bundleID: "us.zoom.xos", volumePercent: volumePercent)])
        }
        let engine = WatchdogAudioRouteEngine()
        let processRegistry = FakeAudioProcessRegistry(
            snapshot: [
                AudioProcessSnapshot(
                    objectID: 42,
                    pid: 1234,
                    bundleID: "us.zoom.xos",
                    name: "zoom.us",
                    isRunningOutput: isRunningOutput,
                    isRunning: isRunning
                )
            ]
        )
        let service = AudioRoutingService(
            ruleStore: store,
            processRegistry: processRegistry,
            deviceRegistry: FakeAudioDeviceRegistry(
                snapshot: [AudioOutputDevice(uid: "speakers", name: "Speakers", isAvailable: true)],
                defaultOutputUID: "speakers"
            ),
            engine: engine,
            persistenceDelay: persistenceDelay,
            recentlyActiveWindow: recentlyActiveWindow,
            now: now
        )
        return ServiceHarness(
            service: service,
            engine: engine,
            store: store,
            processRegistry: processRegistry
        ) {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    @MainActor
    private func makeStableOrderServiceHarness() throws -> ServiceHarness {
        let suiteName = "test.audioRoutingService.order.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = AudioRuleStore(defaults: defaults, key: suiteName)
        try store.save([
            AppAudioRule(bundleID: "com.example.alpha"),
            AppAudioRule(bundleID: "com.example.zulu")
        ])
        let engine = WatchdogAudioRouteEngine()
        let processRegistry = FakeAudioProcessRegistry(
            snapshot: [
                AudioProcessSnapshot(
                    objectID: 1,
                    pid: 101,
                    bundleID: "com.example.alpha",
                    name: "Alpha",
                    isRunningOutput: false
                ),
                AudioProcessSnapshot(
                    objectID: 2,
                    pid: 102,
                    bundleID: "com.example.zulu",
                    name: "Zulu",
                    isRunningOutput: true
                )
            ]
        )
        let service = AudioRoutingService(
            ruleStore: store,
            processRegistry: processRegistry,
            deviceRegistry: FakeAudioDeviceRegistry(
                snapshot: [AudioOutputDevice(uid: "speakers", name: "Speakers", isAvailable: true)],
                defaultOutputUID: "speakers"
            ),
            engine: engine
        )
        return ServiceHarness(
            service: service,
            engine: engine,
            store: store,
            processRegistry: processRegistry
        ) {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    @MainActor
    private func makeTwoRouteServiceHarness() throws -> ServiceHarness {
        let suiteName = "test.audioRoutingService.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = AudioRuleStore(defaults: defaults, key: suiteName)
        try store.save([
            AppAudioRule(bundleID: "com.apple.Music", volumePercent: 200),
            AppAudioRule(
                bundleID: "us.zoom.xos",
                volumePercent: 100,
                outputDeviceUID: "headset"
            )
        ])
        let engine = WatchdogAudioRouteEngine()
        let service = AudioRoutingService(
            ruleStore: store,
            processRegistry: FakeAudioProcessRegistry(
                snapshot: [
                    AudioProcessSnapshot(
                        objectID: 7,
                        pid: 700,
                        bundleID: "com.apple.Music",
                        name: "Music",
                        isRunningOutput: true
                    ),
                    AudioProcessSnapshot(
                        objectID: 42,
                        pid: 1234,
                        bundleID: "us.zoom.xos",
                        name: "zoom.us",
                        isRunningOutput: true
                    )
                ]
            ),
            deviceRegistry: FakeAudioDeviceRegistry(
                snapshot: [
                    AudioOutputDevice(uid: "speakers", name: "Speakers", isAvailable: true),
                    AudioOutputDevice(uid: "headset", name: "Headset", isAvailable: true)
                ],
                defaultOutputUID: "speakers"
            ),
            engine: engine
        )
        return ServiceHarness(service: service, engine: engine, store: store, processRegistry: nil) {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

@MainActor
private final class TestClock {
    private(set) var now: Date

    init(start: Date) {
        now = start
    }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

@MainActor
private struct ServiceHarness {
    let service: AudioRoutingService
    let engine: WatchdogAudioRouteEngine
    let store: AudioRuleStore
    let processRegistry: FakeAudioProcessRegistry?
    let cleanup: () -> Void
}

private final class FakeNativeAudioRouteEngine: AudioRouteNativeEngineControlling {
    var replaceAttemptCount = 0
    var reconcileCalls: [(
        changedPlans: [AudioRoutePlan],
        removingRouteIDs: [String],
        retainedParameters: [AudioRouteNativeRuntimeParameters]
    )] = []
    var parameterUpdates: [[AudioRouteNativeRuntimeParameters]] = []
    var stopReasons: [AudioRouteStopReason] = []
    var fadeOutCalls: [[String]] = []
    var fadeOutAllCallCount = 0
    var reconcileError: Error?
    var stopReport = AudioRouteStopReport(succeeded: true, errorMessage: nil)

    func beginFadeOut(routeIDs: [String]) {
        fadeOutCalls.append(routeIDs)
    }

    func beginFadeOutAll() {
        fadeOutAllCallCount += 1
    }

    func reconcile(
        changedPlans: [AudioRoutePlan],
        removingRouteIDs: [String],
        retainedParameters: [AudioRouteNativeRuntimeParameters]
    ) throws {
        replaceAttemptCount += 1
        if let reconcileError { throw reconcileError }
        reconcileCalls.append((changedPlans, removingRouteIDs, retainedParameters))
    }

    func update(parameters: [AudioRouteNativeRuntimeParameters]) throws {
        parameterUpdates.append(parameters)
    }

    func diagnostics() -> [AudioRouteDiagnosticsSnapshot] {
        []
    }

    var fadeOutDuration: Duration { .zero }

    func performMaintenance() -> Bool { false }

    func stopAll(reason: AudioRouteStopReason) -> AudioRouteStopReport {
        stopReasons.append(reason)
        return stopReport
    }
}

private enum TestError: Error {
    case applyFailed
}

@available(macOS 14.2, *)
private final class RollbackFailingAudioRouteEngine: TBAudioRouteEngine {
    var shouldFailStarts = false
    private(set) var stopAllCallCount = 0

    override func startRoute(
        withIdentifier identifier: String,
        outputDeviceUID: String,
        processObjectIDs: [NSNumber],
        gains: [NSNumber]
    ) throws {
        if shouldFailStarts { throw TestError.applyFailed }
    }

    override func stopRoute(withIdentifier identifier: String) -> Bool {
        true
    }

    override func stopAllRoutes() -> Bool {
        stopAllCallCount += 1
        return true
    }
}

@available(macOS 14.2, *)
private final class CleanupPendingAudioRouteEngine: TBAudioRouteEngine {
    private(set) var startCallCount = 0

    override func startRoute(
        withIdentifier identifier: String,
        outputDeviceUID: String,
        processObjectIDs: [NSNumber],
        gains: [NSNumber]
    ) throws {
        startCallCount += 1
        throw TestError.applyFailed
    }

    override func hasPendingCleanup() -> Bool { true }
}

@MainActor
private final class FakeAudioProcessRegistry: AudioProcessRegistryProviding {
    private let snapshotSubject: CurrentValueSubject<[AudioProcessSnapshot], Never>
    private let errorSubject = CurrentValueSubject<String?, Never>(nil)
    private let restartSnapshot: [AudioProcessSnapshot]?

    init(snapshot: [AudioProcessSnapshot], restartSnapshot: [AudioProcessSnapshot]? = nil) {
        snapshotSubject = CurrentValueSubject(snapshot)
        self.restartSnapshot = restartSnapshot
    }

    var snapshot: [AudioProcessSnapshot] { snapshotSubject.value }
    var snapshotPublisher: AnyPublisher<[AudioProcessSnapshot], Never> {
        snapshotSubject.eraseToAnyPublisher()
    }
    var lastErrorPublisher: AnyPublisher<String?, Never> {
        errorSubject.eraseToAnyPublisher()
    }

    func setSnapshot(_ snapshot: [AudioProcessSnapshot]) {
        snapshotSubject.send(snapshot)
    }

    func start() {}
    func stop() {}
    func refreshAfterAudioServerRestart() {
        if let restartSnapshot {
            snapshotSubject.send(restartSnapshot)
        }
    }
}

@MainActor
private final class FakeAudioDeviceRegistry: AudioDeviceRegistryProviding {
    private let snapshotSubject: CurrentValueSubject<[AudioOutputDevice], Never>
    private let defaultOutputSubject: CurrentValueSubject<String?, Never>
    private let errorSubject = CurrentValueSubject<String?, Never>(nil)
    private let serviceGenerationSubject = CurrentValueSubject<Int, Never>(0)
    private let routeGenerationSubject = CurrentValueSubject<Int, Never>(0)

    var rememberedUIDs: Set<String> = []

    init(snapshot: [AudioOutputDevice], defaultOutputUID: String?) {
        snapshotSubject = CurrentValueSubject(snapshot)
        defaultOutputSubject = CurrentValueSubject(defaultOutputUID)
    }

    var snapshot: [AudioOutputDevice] { snapshotSubject.value }
    var defaultOutputUID: String? { defaultOutputSubject.value }
    var snapshotPublisher: AnyPublisher<[AudioOutputDevice], Never> {
        snapshotSubject.eraseToAnyPublisher()
    }
    var defaultOutputPublisher: AnyPublisher<String?, Never> {
        defaultOutputSubject.eraseToAnyPublisher()
    }
    var lastErrorPublisher: AnyPublisher<String?, Never> {
        errorSubject.eraseToAnyPublisher()
    }
    var serviceGenerationPublisher: AnyPublisher<Int, Never> {
        serviceGenerationSubject.eraseToAnyPublisher()
    }
    var routeGenerationPublisher: AnyPublisher<Int, Never> {
        routeGenerationSubject.eraseToAnyPublisher()
    }

    func publishDefaultOutputUID(_ uid: String?) {
        defaultOutputSubject.send(uid)
    }

    func publishSnapshot(_ snapshot: [AudioOutputDevice]) {
        snapshotSubject.send(snapshot)
    }

    func publishServiceGeneration(_ generation: Int) {
        serviceGenerationSubject.send(generation)
    }

    func start() {}
    func stop() {}
    func refreshAfterAudioServerRestart() {}
}

private actor BlockingRestartAudioRouteEngine: AudioRouteEngineControlling {
    private var restartStops = 0
    private var restartContinuations: [Int: CheckedContinuation<AudioRouteStopReport, Never>] = [:]
    private var countWaiters: [(
        target: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []

    func reconcile(plans: [AudioRoutePlan], generation: UInt64) -> AudioRouteApplyReport {
        AudioRouteApplyReport(generation: generation, status: .applied, plans: plans)
    }

    func update(parameters: [AudioRouteRuntimeParameters]) -> AudioRouteApplyReport {
        AudioRouteApplyReport(
            generation: parameters.first?.generation ?? 0,
            status: .applied,
            plans: []
        )
    }

    func diagnostics() -> [AudioRouteDiagnosticsSnapshot] { [] }

    func stopAll(reason: AudioRouteStopReason) async -> AudioRouteStopReport {
        guard reason == .audioServerRestarted else {
            return AudioRouteStopReport(succeeded: true, errorMessage: nil)
        }

        restartStops += 1
        let number = restartStops
        let readyWaiters = countWaiters.filter { $0.target <= restartStops }
        countWaiters.removeAll { $0.target <= restartStops }
        readyWaiters.forEach { $0.continuation.resume() }
        return await withCheckedContinuation { continuation in
            restartContinuations[number] = continuation
        }
    }

    func waitUntilRestartStopCount(_ target: Int) async {
        guard restartStops < target else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((target, continuation))
        }
    }

    func restartStopCount() -> Int { restartStops }

    func releaseRestartStop(number: Int) {
        restartContinuations.removeValue(forKey: number)?.resume(
            returning: AudioRouteStopReport(succeeded: true, errorMessage: nil)
        )
    }

    func releaseAllRestartStops() {
        let continuations = restartContinuations.values
        restartContinuations.removeAll()
        continuations.forEach {
            $0.resume(returning: AudioRouteStopReport(succeeded: true, errorMessage: nil))
        }
    }
}

private actor ScriptedAudioRouteEngine: AudioRouteEngineControlling {
    private let blockedGeneration: UInt64
    private var observedGenerations: Set<UInt64> = []
    private var observationWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]
    private var blockedContinuation: CheckedContinuation<Void, Never>?

    init(blockedGeneration: UInt64) {
        self.blockedGeneration = blockedGeneration
    }

    func reconcile(plans: [AudioRoutePlan], generation: UInt64) async -> AudioRouteApplyReport {
        observedGenerations.insert(generation)
        observationWaiters.removeValue(forKey: generation)?.forEach { $0.resume() }
        if generation == blockedGeneration {
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
            }
        }
        return AudioRouteApplyReport(generation: generation, status: .applied, plans: plans)
    }

    func update(parameters: [AudioRouteRuntimeParameters]) async -> AudioRouteApplyReport {
        AudioRouteApplyReport(
            generation: parameters.first?.generation ?? 0,
            status: .applied,
            plans: []
        )
    }

    func diagnostics() async -> [AudioRouteDiagnosticsSnapshot] {
        []
    }

    func stopAll(reason: AudioRouteStopReason) async -> AudioRouteStopReport {
        AudioRouteStopReport(succeeded: true, errorMessage: nil)
    }

    func waitUntilObserved(generation: UInt64) async {
        guard !observedGenerations.contains(generation) else { return }
        await withCheckedContinuation { continuation in
            observationWaiters[generation, default: []].append(continuation)
        }
    }

    func releaseBlockedGeneration() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
}

private actor WatchdogAudioRouteEngine: AudioRouteEngineControlling {
    private var plans: [AudioRoutePlan] = []
    private var currentGeneration: UInt64 = 0
    private var reconcileCalls = 0
    private var updateCalls: [[AudioRouteRuntimeParameters]] = []
    private var diagnosticsValue: [AudioRouteDiagnosticsSnapshot] = []
    private var recordedStopReasons: [AudioRouteStopReason] = []
    private var reconcileWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var updateWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var stopWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var shouldBlockNextStop = false
    private var shouldRejectNextUpdateAsStale = false
    private var nextReconcileFailureMessage: String?
    private var nextReconcileCleanupBlockedMessage: String?
    private var stopContinuation: CheckedContinuation<Void, Never>?

    func reconcile(plans: [AudioRoutePlan], generation: UInt64) async -> AudioRouteApplyReport {
        currentGeneration = generation
        reconcileCalls += 1
        resumeReconcileWaiters()
        if let message = nextReconcileFailureMessage {
            nextReconcileFailureMessage = nil
            return AudioRouteApplyReport(generation: generation, status: .failed(message), plans: self.plans)
        }
        if let message = nextReconcileCleanupBlockedMessage {
            nextReconcileCleanupBlockedMessage = nil
            return AudioRouteApplyReport(
                generation: generation,
                status: .cleanupBlocked(message),
                plans: self.plans
            )
        }
        self.plans = plans
        return AudioRouteApplyReport(generation: generation, status: .applied, plans: plans)
    }

    func update(parameters: [AudioRouteRuntimeParameters]) async -> AudioRouteApplyReport {
        updateCalls.append(parameters)
        if shouldRejectNextUpdateAsStale {
            shouldRejectNextUpdateAsStale = false
            resumeUpdateWaiters()
            return AudioRouteApplyReport(
                generation: parameters.first?.generation ?? 0,
                status: .stale,
                plans: plans
            )
        }
        if let generation = parameters.first?.generation {
            currentGeneration = generation
        }
        plans = plans.map { plan in
            let sources = plan.sources.map { source in
                guard let parameter = parameters.first(where: {
                    $0.routeID == plan.id && $0.processObjectID == source.processObjectID
                }) else {
                    return source
                }
                return AudioRouteSource(
                    bundleID: source.bundleID,
                    processObjectID: source.processObjectID,
                    linearGain: parameter.targetGain
                )
            }
            return AudioRoutePlan(
                outputDeviceUID: plan.outputDeviceUID,
                deviceConfigurationGeneration: plan.deviceConfigurationGeneration,
                sources: sources
            )
        }
        resumeUpdateWaiters()
        return AudioRouteApplyReport(
            generation: currentGeneration,
            status: .applied,
            plans: plans
        )
    }

    func diagnostics() async -> [AudioRouteDiagnosticsSnapshot] {
        diagnosticsValue
    }

    func stopAll(reason: AudioRouteStopReason) async -> AudioRouteStopReport {
        recordedStopReasons.append(reason)
        resumeStopWaiters()
        if shouldBlockNextStop {
            shouldBlockNextStop = false
            await withCheckedContinuation { continuation in
                stopContinuation = continuation
            }
        }
        plans = []
        return AudioRouteStopReport(succeeded: true, errorMessage: nil)
    }

    func setDiagnostics(_ value: [AudioRouteDiagnosticsSnapshot]) {
        diagnosticsValue = value
    }

    func stopReasons() -> [AudioRouteStopReason] {
        recordedStopReasons
    }

    func reconcileCount() -> Int {
        reconcileCalls
    }

    func lastUpdate() -> [AudioRouteRuntimeParameters]? {
        updateCalls.last
    }

    func updateCount() -> Int {
        updateCalls.count
    }

    func currentPlans() -> [AudioRoutePlan] {
        plans
    }

    func rejectNextRuntimeUpdateAsStale() {
        shouldRejectNextUpdateAsStale = true
    }

    func failNextReconcileKeepingCurrentPlans(message: String) {
        nextReconcileFailureMessage = message
    }

    func cleanupBlockNextReconcileKeepingCurrentPlans(message: String) {
        nextReconcileCleanupBlockedMessage = message
    }

    func blockNextStop() {
        shouldBlockNextStop = true
    }

    func releaseStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }

    func waitUntilReconcileCount(_ count: Int) async {
        guard reconcileCalls < count else { return }
        await withCheckedContinuation { continuation in
            reconcileWaiters.append((count, continuation))
        }
    }

    func waitUntilUpdateCount(_ count: Int) async {
        guard updateCalls.count < count else { return }
        await withCheckedContinuation { continuation in
            updateWaiters.append((count, continuation))
        }
    }

    func waitUntilStopCount(_ count: Int) async {
        guard recordedStopReasons.count < count else { return }
        await withCheckedContinuation { continuation in
            stopWaiters.append((count, continuation))
        }
    }

    private func resumeReconcileWaiters() {
        let ready = reconcileWaiters.filter { reconcileCalls >= $0.0 }
        reconcileWaiters.removeAll { reconcileCalls >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    private func resumeUpdateWaiters() {
        let ready = updateWaiters.filter { updateCalls.count >= $0.0 }
        updateWaiters.removeAll { updateCalls.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    private func resumeStopWaiters() {
        let ready = stopWaiters.filter { recordedStopReasons.count >= $0.0 }
        stopWaiters.removeAll { recordedStopReasons.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}
