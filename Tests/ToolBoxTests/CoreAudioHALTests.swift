import CoreAudio
import Foundation
import XCTest

@testable import ToolBox

@available(macOS 14.2, *)
final class CoreAudioHALTests: XCTestCase {
    func testObservationIncludesProcessTapAggregateAndOutputFormats() throws {
        let properties = FixtureHALProperties.processOnDeviceAWithTap441AndOutput48()
        let hal = SystemCoreAudioHAL(propertyAccess: properties)

        let snapshot = try hal.observe(
            HALObservationRequest(intent: AudioRouteTestFixtures.intent())
        )
        let route = try XCTUnwrap(snapshot.routesByID["output-A"])

        XCTAssertEqual(route.processDeviceIDsByObjectID[42], [100])
        XCTAssertEqual(route.tapFormatsByProcessObjectID[42]?.sampleRate, 44_100)
        XCTAssertEqual(route.aggregateFormatsByProcessObjectID[42]?.sampleRate, 44_100)
        XCTAssertEqual(route.outputFormat.sampleRate, 48_000)
    }

    func testObservationPropertyFailureIncludesRouteAndStage() throws {
        let properties = FixtureHALProperties.processOnDeviceAWithTap441AndOutput48()
        properties.remove(
            objectID: 200,
            selector: kAudioDevicePropertyNominalSampleRate
        )
        let hal = SystemCoreAudioHAL(propertyAccess: properties)

        XCTAssertThrowsError(
            try hal.observe(
                HALObservationRequest(intent: AudioRouteTestFixtures.intent())
            )
        ) { error in
            XCTAssertEqual(
                error as? AudioRuntimeFailure,
                .prepareFailed(
                    routeID: "output-A",
                    stage: .observe,
                    status: kAudioHardwareBadObjectError
                )
            )
        }
    }

    func testPropertyChangeOnlyPublishesFactEvent() async throws {
        let properties = FixtureHALProperties.processOnDeviceAWithTap441AndOutput48()
        let hal = SystemCoreAudioHAL(propertyAccess: properties)
        let changes = hal.changes(for: [.processDevices(42), .tapFormat(77)])
        var iterator = changes.makeAsyncIterator()

        properties.emit(selector: kAudioProcessPropertyDevices, objectID: 42)

        let change = await iterator.next()
        XCTAssertEqual(change, .propertyChanged)
        XCTAssertEqual(properties.mutationCallCount, 0)
    }

    func testListenerReceiptCancelsExactRegistrationOnce() throws {
        let properties = FixtureHALProperties.processOnDeviceAWithTap441AndOutput48()
        let address = CoreAudioPropertyReader.address(
            kAudioProcessPropertyDevices,
            scope: kAudioObjectPropertyScopeOutput
        )
        let receipt = try properties.addListener(objectID: 42, address: address) {}

        receipt.cancel()
        receipt.cancel()

        XCTAssertEqual(properties.cancelledRegistrations.count, 1)
        XCTAssertEqual(properties.cancelledRegistrations.first?.objectID, 42)
        XCTAssertEqual(
            properties.cancelledRegistrations.first?.selector,
            kAudioProcessPropertyDevices
        )
    }

    func testPrepareFailureRollsBackResourcesInReverseAcquisitionOrder() throws {
        let properties = FixtureHALProperties.processOnDeviceAWithTap441AndOutput48()
        properties.set(
            AudioRouteTestFixtures.format(sampleRate: 44_100),
            objectID: 77,
            selector: kAudioTapPropertyFormat
        )
        properties.set(
            [AudioObjectID(301)],
            objectID: 300,
            selector: kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeInput
        )
        properties.set(
            AudioRouteTestFixtures.format(sampleRate: 44_100),
            objectID: 301,
            selector: kAudioStreamPropertyVirtualFormat
        )
        let resources = RecordingHALResources(failCaptureStart: true)
        let hal = SystemCoreAudioHAL(
            propertyAccess: properties,
            resourceAccess: resources
        )
        let intent = AudioRouteTestFixtures.intent()
        let observation = try hal.observe(HALObservationRequest(intent: intent))
        let transaction = HALTransaction(
            kind: .prepareCandidate,
            routeID: "output-A",
            sourceIDs: [42],
            intent: intent,
            observation: observation,
            replacingKeysByRouteID: [:]
        )

        XCTAssertThrowsError(try hal.execute(transaction))
        XCTAssertEqual(
            resources.operations,
            [
                "createTap", "createAggregate", "createKernel",
                "createCaptureIOProc", "createOutputIOProc",
                "startOutput", "startCapture",
                "detachKernel", "detachOutput", "detachCapture",
                "stopOutput", "destroyOutputIOProc", "destroyOutputLease",
                "stopCapture", "destroyCaptureIOProc", "destroyCaptureLease",
                "destroyAggregate", "destroyTap", "destroyKernel",
            ]
        )
    }

    func testPrepareUsesActualTapFormatInsteadOfPredictedDeviceFormat() throws {
        let properties = FixtureHALProperties.processOnDeviceAWithTap441AndOutput48()
        let actualCaptureFormat = AudioRouteTestFixtures.format(
            sampleRate: 48_000,
            channels: 1,
            nonInterleaved: true
        )
        properties.set(
            actualCaptureFormat,
            objectID: 77,
            selector: kAudioTapPropertyFormat
        )
        properties.set(
            [AudioObjectID(301)],
            objectID: 300,
            selector: kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeInput
        )
        properties.set(
            actualCaptureFormat,
            objectID: 301,
            selector: kAudioStreamPropertyVirtualFormat
        )
        let resources = RecordingHALResources()
        let hal = SystemCoreAudioHAL(
            propertyAccess: properties,
            resourceAccess: resources
        )
        let intent = AudioRouteTestFixtures.intent()
        let observation = try hal.observe(HALObservationRequest(intent: intent))

        _ = try hal.execute(transaction(intent: intent, observation: observation))

        XCTAssertEqual(
            resources.createdKernelSourceFormats,
            [AudioFormatFingerprint(actualCaptureFormat)]
        )
    }

    func testPrepareStartsCaptureWhileAggregateStreamsArePermissionPending() throws {
        let properties = FixtureHALProperties.processOnDeviceAWithTap441AndOutput48()
        let tapFormat = AudioRouteTestFixtures.format(sampleRate: 44_100)
        properties.set(
            tapFormat,
            objectID: 77,
            selector: kAudioTapPropertyFormat
        )
        let resources = RecordingHALResources()
        let hal = SystemCoreAudioHAL(
            propertyAccess: properties,
            resourceAccess: resources
        )
        let intent = AudioRouteTestFixtures.intent()
        let observation = try hal.observe(HALObservationRequest(intent: intent))

        _ = try hal.execute(transaction(intent: intent, observation: observation))

        XCTAssertEqual(
            resources.createdKernelSourceFormats,
            [AudioFormatFingerprint(tapFormat)]
        )
        XCTAssertTrue(resources.operations.contains("startCapture"))
    }

    func testActiveRouteDiagnosticsExposeRealtimeKernelSnapshot() throws {
        let properties = configuredPropertiesForExecution()
        var realtimeSnapshot = TBAudioRealtimeSnapshot()
        realtimeSnapshot.captureCallbackCount = 3
        realtimeSnapshot.captureFrameCount = 768
        realtimeSnapshot.outputCallbackCount = 4
        realtimeSnapshot.outputFrameCount = 1_024
        realtimeSnapshot.ringOccupancyFrames = 256
        realtimeSnapshot.formatMismatchCount = 2
        let resources = RecordingHALResources(realtimeSnapshot: realtimeSnapshot)
        let hal = SystemCoreAudioHAL(
            propertyAccess: properties,
            resourceAccess: resources
        )
        let intent = AudioRouteTestFixtures.intent(generation: 9)
        let observation = try hal.observe(HALObservationRequest(intent: intent))
        _ = try hal.execute(transaction(intent: intent, observation: observation))

        let snapshot = try XCTUnwrap(hal.diagnostics().first)

        XCTAssertEqual(snapshot.routeID, "output-A")
        XCTAssertEqual(snapshot.generation, 9)
        XCTAssertEqual(snapshot.captureCallbackCount, 3)
        XCTAssertEqual(snapshot.captureFrameCount, 768)
        XCTAssertEqual(snapshot.outputCallbackCount, 4)
        XCTAssertEqual(snapshot.outputFrameCount, 1_024)
        XCTAssertEqual(snapshot.ringOccupancyFrames, 256)
        XCTAssertEqual(snapshot.formatMismatchCount, 2)
    }

    func testParameterUpdateChangesGainAndMuteWithoutRebuildingResources() throws {
        let properties = configuredPropertiesForExecution()
        let resources = RecordingHALResources()
        let hal = SystemCoreAudioHAL(
            propertyAccess: properties,
            resourceAccess: resources
        )
        let initial = AudioRouteTestFixtures.intent()
        let observation = try hal.observe(HALObservationRequest(intent: initial))
        _ = try hal.execute(transaction(intent: initial, observation: observation))

        let updated = AudioRuntimeIntent(
            generation: 2,
            plansByID: [
                "output-A": AudioRoutePlan(
                    outputDeviceUID: "output-A",
                    sources: [
                        AudioRouteSource(
                            bundleID: "com.example.player",
                            processObjectID: 42,
                            linearGain: 2
                        )
                    ]
                )
            ],
            mutedRouteIDs: ["output-A"]
        )
        try hal.updateParameters(updated)

        XCTAssertEqual(resources.operations.filter { $0 == "createKernel" }.count, 1)
        XCTAssertEqual(resources.sourceGains, [2])
        XCTAssertEqual(resources.sourceMuteStates, [false, true])
    }

    func testReplacingOneRouteKeepsUnchangedRouteResourcesRunning() throws {
        let properties = configuredPropertiesForTwoRouteExecution()
        let resources = RecordingHALResources(
            realtimeSnapshot: TBAudioRealtimeSnapshot()
        )
        let hal = SystemCoreAudioHAL(
            propertyAccess: properties,
            resourceAccess: resources
        )
        let initialIntent = twoRouteIntent(routeAProcessObjectID: 42, generation: 1)
        let initialObservation = try hal.observe(
            HALObservationRequest(intent: initialIntent)
        )
        let initialReceipt = try hal.execute(
            HALTransaction(
                kind: .prepareCandidate,
                routeID: "output-A",
                sourceIDs: [42, 43],
                intent: initialIntent,
                observation: initialObservation,
                replacingKeysByRouteID: [:]
            )
        )
        resources.resetOperations()

        let changedIntent = twoRouteIntent(routeAProcessObjectID: 44, generation: 2)
        let changedObservation = try hal.observe(
            HALObservationRequest(intent: changedIntent)
        )
        _ = try hal.execute(
            HALTransaction(
                kind: .prepareCandidate,
                routeID: "output-A",
                sourceIDs: [44],
                intent: changedIntent,
                observation: changedObservation,
                replacingKeysByRouteID: initialReceipt.realizedKeysByRouteID
            )
        )

        XCTAssertEqual(resources.operations.filter { $0 == "destroyTap" }.count, 1)
        XCTAssertEqual(resources.operations.filter { $0 == "destroyAggregate" }.count, 1)
        XCTAssertEqual(resources.operations.filter { $0 == "destroyKernel" }.count, 1)
        XCTAssertEqual(resources.operations.filter { $0 == "createTap" }.count, 1)
        XCTAssertEqual(resources.operations.filter { $0 == "createAggregate" }.count, 1)
        XCTAssertEqual(resources.operations.filter { $0 == "createKernel" }.count, 1)
        XCTAssertEqual(
            hal.diagnostics().map(\.generation),
            [changedIntent.generation, changedIntent.generation]
        )
    }

    func testRemovingOneRouteKeepsUnchangedRouteResourcesRunning() throws {
        let properties = configuredPropertiesForTwoRouteExecution()
        let resources = RecordingHALResources(
            realtimeSnapshot: TBAudioRealtimeSnapshot()
        )
        let hal = SystemCoreAudioHAL(
            propertyAccess: properties,
            resourceAccess: resources
        )
        let initialIntent = twoRouteIntent(routeAProcessObjectID: 42, generation: 1)
        let initialObservation = try hal.observe(
            HALObservationRequest(intent: initialIntent)
        )
        let initialReceipt = try hal.execute(
            HALTransaction(
                kind: .prepareCandidate,
                routeID: "output-A",
                sourceIDs: [42, 43],
                intent: initialIntent,
                observation: initialObservation,
                replacingKeysByRouteID: [:]
            )
        )
        resources.resetOperations()

        let retainedRouteA = try XCTUnwrap(initialIntent.plansByID["output-A"])
        let changedIntent = AudioRuntimeIntent(
            generation: 2,
            plansByID: [retainedRouteA.id: retainedRouteA],
            mutedRouteIDs: []
        )
        let changedObservation = try hal.observe(
            HALObservationRequest(intent: changedIntent)
        )
        _ = try hal.execute(
            HALTransaction(
                kind: .prepareCandidate,
                routeID: "output-B",
                sourceIDs: [43],
                intent: changedIntent,
                observation: changedObservation,
                replacingKeysByRouteID: initialReceipt.realizedKeysByRouteID
            )
        )

        XCTAssertEqual(resources.operations.filter { $0 == "destroyTap" }.count, 1)
        XCTAssertEqual(resources.operations.filter { $0 == "destroyAggregate" }.count, 1)
        XCTAssertEqual(resources.operations.filter { $0 == "destroyKernel" }.count, 1)
        XCTAssertFalse(resources.operations.contains("createTap"))
        XCTAssertFalse(resources.operations.contains("createAggregate"))
        XCTAssertFalse(resources.operations.contains("createKernel"))
        XCTAssertEqual(hal.diagnostics().map(\.routeID), ["output-A"])
        XCTAssertEqual(hal.diagnostics().map(\.generation), [changedIntent.generation])
    }

    func testResourceFailureIsAttributedToTheRouteBeingPrepared() throws {
        let properties = configuredPropertiesForExecution()
        let resources = RecordingHALResources(createOutputStatus: -50)
        let hal = SystemCoreAudioHAL(
            propertyAccess: properties,
            resourceAccess: resources
        )
        let intent = AudioRouteTestFixtures.intent()
        let observation = try hal.observe(HALObservationRequest(intent: intent))

        XCTAssertThrowsError(
            try hal.execute(transaction(intent: intent, observation: observation))
        ) { error in
            XCTAssertEqual(
                error as? AudioRuntimeFailure,
                .prepareFailed(routeID: "output-A", stage: .createIOProc, status: -50)
            )
        }
    }

    func testCleanupFailureRetainsResourceStageStatusAndObjectID() throws {
        let properties = configuredPropertiesForExecution()
        let resources = RecordingHALResources(destroyAggregateStatus: -66748)
        let hal = SystemCoreAudioHAL(
            propertyAccess: properties,
            resourceAccess: resources
        )
        let intent = AudioRouteTestFixtures.intent()
        let observation = try hal.observe(HALObservationRequest(intent: intent))
        _ = try hal.execute(transaction(intent: intent, observation: observation))
        let emptyIntent = AudioRuntimeIntent(
            generation: intent.generation + 1,
            plansByID: [:],
            mutedRouteIDs: []
        )

        XCTAssertThrowsError(
            try hal.execute(
                HALTransaction(
                    kind: .shutdown,
                    routeID: "output-A",
                    sourceIDs: [42],
                    intent: emptyIntent,
                    observation: HALObservationSnapshot(
                        audioServerGeneration: 0,
                        routesByID: [:]
                    ),
                    replacingKeysByRouteID: [:]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? AudioRuntimeFailure,
                .cleanupDeferred(
                    routeID: "output-A",
                    failures: [
                        HALCleanupFailure(
                            routeID: "output-A",
                            resource: .aggregateDevice,
                            objectID: 300,
                            stage: .destroyAggregate,
                            status: -66748
                        )
                    ]
                )
            )
        }
    }

    func testPrepareCleanupDebtIsRetainedUntilMaintenanceReleasesIt() throws {
        let properties = configuredPropertiesForExecution()
        let resources = RecordingHALResources(
            failCaptureStart: true,
            destroyAggregateStatuses: [-66748, noErr]
        )
        let hal = SystemCoreAudioHAL(
            propertyAccess: properties,
            resourceAccess: resources
        )
        let intent = AudioRouteTestFixtures.intent()
        let observation = try hal.observe(HALObservationRequest(intent: intent))

        XCTAssertThrowsError(
            try hal.execute(transaction(intent: intent, observation: observation))
        )
        XCTAssertEqual(hal.performMaintenance(), .succeeded)
        XCTAssertEqual(resources.operations.filter { $0 == "destroyAggregate" }.count, 2)
        XCTAssertTrue(
            resources.operations.suffix(3).elementsEqual([
                "destroyAggregate", "destroyTap", "destroyKernel",
            ]))
    }

    // MARK: - Process tap reuse on output switch

    func testProcessTapIsReusedWhenProcessAndCaptureDeviceMatchAcrossOutputSwitch() throws {
        let properties = tapReuseProperties()
        let resources = RecordingHALResources(
            realtimeSnapshot: TBAudioRealtimeSnapshot()
        )
        let hal = SystemCoreAudioHAL(
            propertyAccess: properties,
            resourceAccess: resources
        )

        // Route A: process 42 captured from device-A (its single listed device).
        let initialIntent = tapReuseIntent(
            routeID: "output-A",
            processObjectID: 42,
            generation: 1
        )
        let initialObservation = try hal.observe(
            HALObservationRequest(intent: initialIntent)
        )
        let initialReceipt = try hal.execute(
            HALTransaction(
                kind: .prepareCandidate,
                routeID: "output-A",
                sourceIDs: [42],
                intent: initialIntent,
                observation: initialObservation,
                replacingKeysByRouteID: [:]
            )
        )
        // The single tap created so far is route A's (objectID 77).
        let originalTapObjectID = try XCTUnwrap(resources.createdTapObjectIDs.first)
        XCTAssertEqual(resources.createdTapObjectIDs, [originalTapObjectID])
        resources.resetOperations()

        // Process 42 migrates to route B (output-B) but still captures device-A —
        // the REDIRECT case where selectCaptureDevice binds the tap identically.
        let migratedIntent = tapReuseIntent(
            routeID: "output-B",
            processObjectID: 42,
            generation: 2
        )
        let migratedObservation = try hal.observe(
            HALObservationRequest(intent: migratedIntent)
        )
        _ = try hal.execute(
            HALTransaction(
                kind: .prepareCandidate,
                routeID: "output-B",
                sourceIDs: [42],
                intent: migratedIntent,
                observation: migratedObservation,
                replacingKeysByRouteID: initialReceipt.realizedKeysByRouteID
            )
        )

        // No new tap was created and the migrated tap was not destroyed: it was
        // reused (spared during cleanup and claimed by route B).
        XCTAssertFalse(
            resources.operations.contains("createTap"),
            "Process tap should be reused, not recreated."
        )
        XCTAssertFalse(
            resources.operations.contains("destroyTap"),
            "Reused process tap should be spared during the switch."
        )
        XCTAssertEqual(resources.createdTapObjectIDs, [originalTapObjectID])
        XCTAssertTrue(resources.destroyedTapObjectIDs.isEmpty)
        XCTAssertEqual(
            hal.diagnostics().map(\.routeID),
            ["output-B"],
            "Route B should be the only active route after migration."
        )

        // Confirm route B holds the SAME tap object as route A had: tearing it
        // down destroys exactly the original objectID.
        let shutdownIntent = AudioRuntimeIntent(
            generation: 3,
            plansByID: [:],
            mutedRouteIDs: []
        )
        _ = try hal.execute(
            HALTransaction(
                kind: .shutdown,
                routeID: "output-B",
                sourceIDs: [42],
                intent: shutdownIntent,
                observation: HALObservationSnapshot(
                    audioServerGeneration: 0,
                    routesByID: [:]
                ),
                replacingKeysByRouteID: [:]
            )
        )
        XCTAssertEqual(resources.destroyedTapObjectIDs, [originalTapObjectID])
    }

    func testProcessTapIsNotReusedWhenProcessObjectIDDiffers() throws {
        let properties = tapReuseProperties()
        let resources = RecordingHALResources(
            realtimeSnapshot: TBAudioRealtimeSnapshot()
        )
        let hal = SystemCoreAudioHAL(
            propertyAccess: properties,
            resourceAccess: resources
        )

        let initialIntent = tapReuseIntent(
            routeID: "output-A",
            processObjectID: 42,
            generation: 1
        )
        let initialObservation = try hal.observe(
            HALObservationRequest(intent: initialIntent)
        )
        let initialReceipt = try hal.execute(
            HALTransaction(
                kind: .prepareCandidate,
                routeID: "output-A",
                sourceIDs: [42],
                intent: initialIntent,
                observation: initialObservation,
                replacingKeysByRouteID: [:]
            )
        )
        let routeATapObjectID = try XCTUnwrap(resources.createdTapObjectIDs.first)
        resources.resetOperations()

        // A different app (process 44) takes route B: the tap must be created fresh.
        let migratedIntent = tapReuseIntent(
            routeID: "output-B",
            processObjectID: 44,
            generation: 2
        )
        let migratedObservation = try hal.observe(
            HALObservationRequest(intent: migratedIntent)
        )
        _ = try hal.execute(
            HALTransaction(
                kind: .prepareCandidate,
                routeID: "output-B",
                sourceIDs: [44],
                intent: migratedIntent,
                observation: migratedObservation,
                replacingKeysByRouteID: initialReceipt.realizedKeysByRouteID
            )
        )

        XCTAssertEqual(
            resources.operations.filter { $0 == "createTap" }.count, 1,
            "A different process should get a fresh tap."
        )
        // Route A's tap is torn down (process 42 is gone from the new intent).
        XCTAssertEqual(resources.destroyedTapObjectIDs, [routeATapObjectID])
        // The freshly-created tap is distinct from route A's original.
        let routeBTapObjectID = try XCTUnwrap(resources.createdTapObjectIDs.last)
        XCTAssertNotEqual(routeATapObjectID, routeBTapObjectID)
    }

    func testProcessTapIsNotReusedWhenCaptureDeviceUIDDiffers() throws {
        let properties = tapReuseProperties()
        let resources = RecordingHALResources(
            realtimeSnapshot: TBAudioRealtimeSnapshot()
        )
        let hal = SystemCoreAudioHAL(
            propertyAccess: properties,
            resourceAccess: resources
        )

        let initialIntent = tapReuseIntent(
            routeID: "output-A",
            processObjectID: 42,
            generation: 1
        )
        let initialObservation = try hal.observe(
            HALObservationRequest(intent: initialIntent)
        )
        let initialReceipt = try hal.execute(
            HALTransaction(
                kind: .prepareCandidate,
                routeID: "output-A",
                sourceIDs: [42],
                intent: initialIntent,
                observation: initialObservation,
                replacingKeysByRouteID: [:]
            )
        )
        let routeATapObjectID = try XCTUnwrap(resources.createdTapObjectIDs.first)
        resources.resetOperations()

        // Same process 42, but it now captures device-B instead of device-A. The
        // capture device binding differs, so the tap cannot be reused.
        properties.set(
            [AudioObjectID(110)],
            objectID: 42,
            selector: kAudioProcessPropertyDevices,
            scope: kAudioObjectPropertyScopeOutput
        )
        let migratedIntent = tapReuseIntent(
            routeID: "output-B",
            processObjectID: 42,
            generation: 2
        )
        let migratedObservation = try hal.observe(
            HALObservationRequest(intent: migratedIntent)
        )
        _ = try hal.execute(
            HALTransaction(
                kind: .prepareCandidate,
                routeID: "output-B",
                sourceIDs: [42],
                intent: migratedIntent,
                observation: migratedObservation,
                replacingKeysByRouteID: initialReceipt.realizedKeysByRouteID
            )
        )

        XCTAssertEqual(
            resources.operations.filter { $0 == "createTap" }.count, 1,
            "A different capture device binding should get a fresh tap."
        )
        XCTAssertEqual(resources.destroyedTapObjectIDs, [routeATapObjectID])
        let routeBTapObjectID = try XCTUnwrap(resources.createdTapObjectIDs.last)
        XCTAssertNotEqual(routeATapObjectID, routeBTapObjectID)
    }

    private func tapReuseIntent(
        routeID: String,
        processObjectID: UInt32,
        generation: UInt64
    ) -> AudioRuntimeIntent {
        let plan = AudioRoutePlan(
            outputDeviceUID: routeID,
            sources: [
                AudioRouteSource(
                    bundleID: "com.example.player",
                    processObjectID: processObjectID,
                    linearGain: 1
                )
            ]
        )
        return AudioRuntimeIntent(
            generation: generation,
            plansByID: [plan.id: plan],
            mutedRouteIDs: []
        )
    }

    private func tapReuseProperties() -> FixtureHALProperties {
        let properties = FixtureHALProperties()
        // Two output devices.
        properties.setDeviceID(200, forUID: "output-A")
        properties.setDeviceID(400, forUID: "output-B")
        // Two capture devices the processes can be bound to.
        properties.setDeviceID(100, forUID: "device-A")
        properties.setDeviceID(110, forUID: "device-B")
        // Process 42 starts captured from device-A; process 44 from device-A too.
        properties.set(
            [AudioObjectID(100)], objectID: 42, selector: kAudioProcessPropertyDevices,
            scope: kAudioObjectPropertyScopeOutput)
        properties.set(
            [AudioObjectID(100)], objectID: 44, selector: kAudioProcessPropertyDevices,
            scope: kAudioObjectPropertyScopeOutput)
        // Capture device stream formats (44.1k).
        properties.set(
            [AudioObjectID(101)], objectID: 100, selector: kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeOutput)
        properties.set(
            AudioRouteTestFixtures.format(sampleRate: 44_100), objectID: 101,
            selector: kAudioStreamPropertyVirtualFormat)
        properties.set(
            [AudioObjectID(111)], objectID: 110, selector: kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeOutput)
        properties.set(
            AudioRouteTestFixtures.format(sampleRate: 44_100), objectID: 111,
            selector: kAudioStreamPropertyVirtualFormat)
        // Output device stream formats + alive + nominal rate (48k).
        for outputID: AudioObjectID in [200, 400] {
            let streamID: AudioObjectID = outputID == 200 ? 201 : 401
            properties.set(
                [streamID], objectID: outputID,
                selector: kAudioDevicePropertyStreams,
                scope: kAudioObjectPropertyScopeOutput)
            properties.set(
                AudioRouteTestFixtures.format(sampleRate: 48_000), objectID: streamID,
                selector: kAudioStreamPropertyVirtualFormat)
            properties.set(
                UInt32(1), objectID: outputID, selector: kAudioDevicePropertyDeviceIsAlive)
            properties.set(
                Float64(48_000), objectID: outputID,
                selector: kAudioDevicePropertyNominalSampleRate)
        }
        // Process tap formats: the recording resource hands out object IDs 77, 78, ...
        // per create, so register a format for each.
        for tapObjectID: AudioObjectID in 77...90 {
            properties.set(
                AudioRouteTestFixtures.format(sampleRate: 44_100),
                objectID: tapObjectID,
                selector: kAudioTapPropertyFormat
            )
        }
        // Aggregate device (createAggregate always returns 300) input streams.
        properties.set(
            [AudioObjectID(301)], objectID: 300, selector: kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeInput)
        properties.set(
            AudioRouteTestFixtures.format(sampleRate: 44_100), objectID: 301,
            selector: kAudioStreamPropertyVirtualFormat)
        return properties
    }


    private func configuredPropertiesForExecution() -> FixtureHALProperties {
        let properties = FixtureHALProperties.processOnDeviceAWithTap441AndOutput48()
        properties.set(
            AudioRouteTestFixtures.format(sampleRate: 44_100),
            objectID: 77,
            selector: kAudioTapPropertyFormat
        )
        properties.set(
            [AudioObjectID(301)],
            objectID: 300,
            selector: kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeInput
        )
        properties.set(
            AudioRouteTestFixtures.format(sampleRate: 44_100),
            objectID: 301,
            selector: kAudioStreamPropertyVirtualFormat
        )
        return properties
    }

    private func configuredPropertiesForTwoRouteExecution() -> FixtureHALProperties {
        let properties = configuredPropertiesForExecution()
        // The recording resource hands out a fresh process-tap object ID per create
        // (77, 78, 79, ...); register a tap format for each so prepareRoute can read
        // kAudioTapPropertyFormat regardless of how many taps a test creates.
        for tapObjectID: AudioObjectID in 78...90 {
            properties.set(
                AudioRouteTestFixtures.format(sampleRate: 44_100),
                objectID: tapObjectID,
                selector: kAudioTapPropertyFormat
            )
        }
        properties.setDeviceID(400, forUID: "output-B")
        properties.setDeviceID(110, forUID: "device-B")
        properties.set(
            [AudioObjectID(110)],
            objectID: 43,
            selector: kAudioProcessPropertyDevices,
            scope: kAudioObjectPropertyScopeOutput
        )
        properties.set(
            [AudioObjectID(100)],
            objectID: 44,
            selector: kAudioProcessPropertyDevices,
            scope: kAudioObjectPropertyScopeOutput
        )
        properties.set(
            [AudioObjectID(111)],
            objectID: 110,
            selector: kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeOutput
        )
        properties.set(
            AudioRouteTestFixtures.format(sampleRate: 44_100),
            objectID: 111,
            selector: kAudioStreamPropertyVirtualFormat
        )
        properties.set(
            [AudioObjectID(401)],
            objectID: 400,
            selector: kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeOutput
        )
        properties.set(
            AudioRouteTestFixtures.format(sampleRate: 48_000),
            objectID: 401,
            selector: kAudioStreamPropertyVirtualFormat
        )
        properties.set(
            UInt32(1),
            objectID: 400,
            selector: kAudioDevicePropertyDeviceIsAlive
        )
        properties.set(
            Float64(48_000),
            objectID: 400,
            selector: kAudioDevicePropertyNominalSampleRate
        )
        return properties
    }

    private func twoRouteIntent(
        routeAProcessObjectID: UInt32,
        generation: UInt64
    ) -> AudioRuntimeIntent {
        let routeA = AudioRoutePlan(
            outputDeviceUID: "output-A",
            sources: [
                AudioRouteSource(
                    bundleID: "com.example.player-a",
                    processObjectID: routeAProcessObjectID,
                    linearGain: 1
                )
            ]
        )
        let routeB = AudioRoutePlan(
            outputDeviceUID: "output-B",
            sources: [
                AudioRouteSource(
                    bundleID: "com.example.player-b",
                    processObjectID: 43,
                    linearGain: 1
                )
            ]
        )
        return AudioRuntimeIntent(
            generation: generation,
            plansByID: [routeA.id: routeA, routeB.id: routeB],
            mutedRouteIDs: []
        )
    }

    private func transaction(
        intent: AudioRuntimeIntent,
        observation: HALObservationSnapshot
    ) -> HALTransaction {
        HALTransaction(
            kind: .prepareCandidate,
            routeID: "output-A",
            sourceIDs: [42],
            intent: intent,
            observation: observation,
            replacingKeysByRouteID: [:]
        )
    }
}

private final class FixtureHALProperties: CoreAudioPropertyAccess, @unchecked Sendable {
    struct Registration: Equatable {
        let objectID: AudioObjectID
        let selector: AudioObjectPropertySelector
        let scope: AudioObjectPropertyScope
    }

    private struct Key: Hashable {
        let objectID: AudioObjectID
        let selector: AudioObjectPropertySelector
        let scope: AudioObjectPropertyScope
    }

    private let lock = NSLock()
    private var deviceIDsByUID: [String: AudioObjectID] = [:]
    private var bytesByKey: [Key: Data] = [:]
    private var listeners: [Key: [UUID: @Sendable () -> Void]] = [:]
    private(set) var cancelledRegistrations: [Registration] = []
    private(set) var mutationCallCount = 0

    static func processOnDeviceAWithTap441AndOutput48() -> FixtureHALProperties {
        let properties = FixtureHALProperties()
        properties.deviceIDsByUID["output-A"] = 200
        properties.deviceIDsByUID["device-A"] = 100
        properties.set(
            [AudioObjectID(100)], objectID: 42, selector: kAudioProcessPropertyDevices,
            scope: kAudioObjectPropertyScopeOutput)
        properties.set(
            [AudioObjectID(101)], objectID: 100, selector: kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeOutput)
        properties.set(
            AudioRouteTestFixtures.format(sampleRate: 44_100), objectID: 101,
            selector: kAudioStreamPropertyVirtualFormat)
        properties.set(
            [AudioObjectID(201)], objectID: 200, selector: kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeOutput)
        properties.set(
            AudioRouteTestFixtures.format(sampleRate: 48_000), objectID: 201,
            selector: kAudioStreamPropertyVirtualFormat)
        properties.set(UInt32(1), objectID: 200, selector: kAudioDevicePropertyDeviceIsAlive)
        properties.set(
            Float64(48_000), objectID: 200,
            selector: kAudioDevicePropertyNominalSampleRate)
        return properties
    }

    func deviceID(forUID uid: String) throws -> AudioObjectID {
        guard let deviceID = deviceIDsByUID[uid] else {
            throw CoreAudioHALError.missingValue(
                AudioObjectID(kAudioObjectSystemObject),
                kAudioHardwarePropertyTranslateUIDToDevice
            )
        }
        return deviceID
    }

    func deviceUID(forID deviceID: AudioObjectID) throws -> String {
        guard let uid = deviceIDsByUID.first(where: { $0.value == deviceID })?.key else {
            throw CoreAudioHALError.missingValue(deviceID, kAudioDevicePropertyDeviceUID)
        }
        return uid
    }

    func dataSize(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> UInt32 {
        UInt32(try data(objectID: objectID, address: address).count)
    }

    func readData(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        into buffer: UnsafeMutableRawBufferPointer
    ) throws -> UInt32 {
        let data = try data(objectID: objectID, address: address)
        guard data.count == buffer.count else {
            throw CoreAudioHALError.missingValue(objectID, address.mSelector)
        }
        data.copyBytes(to: buffer)
        return UInt32(data.count)
    }

    func addListener(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        handler: @escaping @Sendable () -> Void
    ) throws -> HALListenerReceipt {
        let key = Key(objectID: objectID, selector: address.mSelector, scope: address.mScope)
        let id = UUID()
        lock.lock()
        listeners[key, default: [:]][id] = handler
        lock.unlock()
        return HALListenerReceipt { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.listeners[key]?[id] = nil
            self.cancelledRegistrations.append(
                Registration(objectID: objectID, selector: address.mSelector, scope: address.mScope)
            )
            self.lock.unlock()
        }
    }

    func emit(selector: AudioObjectPropertySelector, objectID: AudioObjectID) {
        lock.lock()
        let handlers =
            listeners
            .filter { $0.key.objectID == objectID && $0.key.selector == selector }
            .flatMap(\.value.values)
        lock.unlock()
        for handler in handlers {
            handler()
        }
    }

    fileprivate func set<T>(
        _ value: T,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) {
        var value = value
        bytesByKey[Key(objectID: objectID, selector: selector, scope: scope)] =
            withUnsafeBytes(of: &value) { Data($0) }
    }

    fileprivate func setDeviceID(_ deviceID: AudioObjectID, forUID uid: String) {
        deviceIDsByUID[uid] = deviceID
    }

    fileprivate func remove(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) {
        bytesByKey[Key(objectID: objectID, selector: selector, scope: scope)] = nil
    }

    fileprivate func set<T>(
        _ values: [T],
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) {
        bytesByKey[Key(objectID: objectID, selector: selector, scope: scope)] =
            values.withUnsafeBytes { Data($0) }
    }

    private func data(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> Data {
        let key = Key(objectID: objectID, selector: address.mSelector, scope: address.mScope)
        guard let data = bytesByKey[key] else {
            throw CoreAudioHALError.missingValue(objectID, address.mSelector)
        }
        return data
    }
}

@available(macOS 14.2, *)
private final class RecordingHALResources: CoreAudioResourceAccess {
    private(set) var operations: [String] = []
    private(set) var createdKernelSourceFormats: [AudioFormatFingerprint] = []
    private(set) var sourceGains: [Float] = []
    private(set) var sourceMuteStates: [Bool] = []
    private(set) var createdTapObjectIDs: [AudioObjectID] = []
    private(set) var destroyedTapObjectIDs: [AudioObjectID] = []
    private var nextTapObjectID: AudioObjectID = 77
    private let failCaptureStart: Bool
    private let createOutputStatus: OSStatus
    private let realtimeSnapshot: TBAudioRealtimeSnapshot?
    private var destroyAggregateStatuses: [OSStatus]

    init(
        failCaptureStart: Bool = false,
        createOutputStatus: OSStatus = noErr,
        realtimeSnapshot: TBAudioRealtimeSnapshot? = nil,
        destroyAggregateStatus: OSStatus = noErr,
        destroyAggregateStatuses: [OSStatus] = []
    ) {
        self.failCaptureStart = failCaptureStart
        self.createOutputStatus = createOutputStatus
        self.realtimeSnapshot = realtimeSnapshot
        self.destroyAggregateStatuses =
            destroyAggregateStatuses.isEmpty
            ? [destroyAggregateStatus]
            : destroyAggregateStatuses
    }

    func resetOperations() {
        operations = []
    }

    func createKernel(
        generation: UInt64,
        sourceFormats: [AudioFormatFingerprint],
        outputFormat: AudioFormatFingerprint,
        targetFrames: UInt32,
        rampFrames: UInt32,
        gains: [Float]
    ) throws -> HALKernelResource {
        operations.append("createKernel")
        createdKernelSourceFormats = sourceFormats
        return HALKernelResource(pointer: nil)
    }

    func detachKernel(_ kernel: HALKernelResource) { operations.append("detachKernel") }
    func destroyKernel(_ kernel: HALKernelResource) { operations.append("destroyKernel") }

    func createProcessTap(
        routeID: String,
        processObjectID: AudioObjectID,
        deviceUID: String?
    ) throws -> HALTapResource {
        operations.append("createTap")
        let objectID = nextTapObjectID
        nextTapObjectID += 1
        createdTapObjectIDs.append(objectID)
        return HALTapResource(objectID: objectID, uid: "tap-\(objectID)")
    }

    func destroyProcessTap(_ tap: HALTapResource) -> OSStatus {
        operations.append("destroyTap")
        destroyedTapObjectIDs.append(tap.objectID)
        return noErr
    }

    func createAggregate(
        routeID: String,
        outputDeviceUID: String,
        tapUID: String
    ) throws -> AudioObjectID {
        operations.append("createAggregate")
        return 300
    }

    func destroyAggregate(_ aggregateID: AudioObjectID) -> OSStatus {
        operations.append("destroyAggregate")
        if destroyAggregateStatuses.count > 1 {
            return destroyAggregateStatuses.removeFirst()
        }
        return destroyAggregateStatuses[0]
    }

    func createCaptureIOProc(
        deviceID: AudioObjectID,
        kernel: HALKernelResource,
        generation: UInt64,
        sourceIndex: UInt32
    ) throws -> HALIOProcResource {
        operations.append("createCaptureIOProc")
        return HALIOProcResource(deviceID: deviceID, ioProcID: nil, lease: nil)
    }

    func createOutputIOProc(
        deviceID: AudioObjectID,
        kernel: HALKernelResource,
        generation: UInt64
    ) throws -> HALIOProcResource {
        operations.append("createOutputIOProc")
        if createOutputStatus != noErr {
            throw AudioRuntimeFailure.prepareFailed(
                routeID: "",
                stage: .createIOProc,
                status: createOutputStatus
            )
        }
        return HALIOProcResource(deviceID: deviceID, ioProcID: nil, lease: nil)
    }

    func snapshot(_ kernel: HALKernelResource) -> TBAudioRealtimeSnapshot? {
        realtimeSnapshot
    }

    func setSourceGain(_ gain: Float, index: UInt32, kernel: HALKernelResource) {
        sourceGains.append(gain)
    }

    func setSourceMuted(
        _ muted: Bool,
        index: UInt32,
        rampFrames: UInt32,
        kernel: HALKernelResource
    ) {
        sourceMuteStates.append(muted)
    }

    func start(_ ioProc: HALIOProcResource) -> OSStatus {
        let isOutput = ioProc.deviceID == 200
        operations.append(isOutput ? "startOutput" : "startCapture")
        return failCaptureStart && !isOutput ? -1 : noErr
    }

    func detach(_ ioProc: HALIOProcResource) {
        operations.append(ioProc.deviceID == 200 ? "detachOutput" : "detachCapture")
    }

    func stop(_ ioProc: HALIOProcResource) -> OSStatus {
        operations.append(ioProc.deviceID == 200 ? "stopOutput" : "stopCapture")
        return noErr
    }

    func destroyIOProc(_ ioProc: HALIOProcResource) -> OSStatus {
        operations.append(
            ioProc.deviceID == 200 ? "destroyOutputIOProc" : "destroyCaptureIOProc"
        )
        return noErr
    }

    func destroyLease(_ ioProc: HALIOProcResource) -> OSStatus {
        operations.append(
            ioProc.deviceID == 200 ? "destroyOutputLease" : "destroyCaptureLease"
        )
        return noErr
    }
}
