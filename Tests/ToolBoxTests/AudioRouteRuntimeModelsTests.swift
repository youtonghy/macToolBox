import XCTest
@testable import ToolBox

final class AudioRouteRuntimeModelsTests: XCTestCase {
    func testRealizationKeyChangesWhenObservedTapFormatChanges() {
        let first = AudioRouteTestFixtures.observation(tapSampleRate: 44_100)
        let second = AudioRouteTestFixtures.observation(tapSampleRate: 48_000)

        XCTAssertNotEqual(
            RealizationKey(
                routeID: "output-A",
                intent: AudioRouteTestFixtures.intent(),
                observation: first
            ),
            RealizationKey(
                routeID: "output-A",
                intent: AudioRouteTestFixtures.intent(),
                observation: second
            )
        )
    }

    func testRealizationKeyChangesWhenObservedProcessDeviceChanges() {
        let first = AudioRouteTestFixtures.observation(processDeviceID: 100)
        let second = AudioRouteTestFixtures.observation(processDeviceID: 101)

        XCTAssertNotEqual(
            RealizationKey(
                routeID: "output-A",
                intent: AudioRouteTestFixtures.intent(),
                observation: first
            ),
            RealizationKey(
                routeID: "output-A",
                intent: AudioRouteTestFixtures.intent(),
                observation: second
            )
        )
    }

    func testRealizationKeyChangesWhenObservedAggregateFormatChanges() {
        let first = AudioRouteTestFixtures.observation(aggregateSampleRate: 44_100)
        let second = AudioRouteTestFixtures.observation(aggregateSampleRate: 48_000)

        XCTAssertNotEqual(
            RealizationKey(
                routeID: "output-A",
                intent: AudioRouteTestFixtures.intent(),
                observation: first
            ),
            RealizationKey(
                routeID: "output-A",
                intent: AudioRouteTestFixtures.intent(),
                observation: second
            )
        )
    }

    func testRealizationKeyChangesWhenObservedOutputFormatChanges() {
        let first = AudioRouteTestFixtures.observation(outputSampleRate: 44_100)
        let second = AudioRouteTestFixtures.observation(outputSampleRate: 48_000)

        XCTAssertNotEqual(
            RealizationKey(
                routeID: "output-A",
                intent: AudioRouteTestFixtures.intent(),
                observation: first
            ),
            RealizationKey(
                routeID: "output-A",
                intent: AudioRouteTestFixtures.intent(),
                observation: second
            )
        )
    }

    func testGainOnlyIntentKeepsGraphFingerprint() {
        let first = AudioRouteTestFixtures.intent(gain: 1)
        let second = AudioRouteTestFixtures.intent(gain: 2)

        XCTAssertEqual(first.graphFingerprint, second.graphFingerprint)
        XCTAssertNotEqual(first.parameterFingerprint, second.parameterFingerprint)
    }

    func testRealizationKeyIgnoresUnrelatedRouteTopologyChanges() throws {
        let routeA = AudioRoutePlan(
            outputDeviceUID: "output-A",
            sources: [
                AudioRouteSource(
                    bundleID: "com.example.player-a",
                    processObjectID: 42,
                    linearGain: 1
                )
            ]
        )
        let originalRouteB = AudioRoutePlan(
            outputDeviceUID: "output-B",
            sources: [
                AudioRouteSource(
                    bundleID: "com.example.player-b",
                    processObjectID: 43,
                    linearGain: 1
                )
            ]
        )
        let changedRouteB = AudioRoutePlan(
            outputDeviceUID: "output-B",
            sources: [
                AudioRouteSource(
                    bundleID: "com.example.player-c",
                    processObjectID: 44,
                    linearGain: 1
                )
            ]
        )
        let observation = AudioRouteTestFixtures.observation()
        let originalIntent = AudioRuntimeIntent(
            generation: 1,
            plansByID: [routeA.id: routeA, originalRouteB.id: originalRouteB],
            mutedRouteIDs: []
        )
        let changedIntent = AudioRuntimeIntent(
            generation: 2,
            plansByID: [routeA.id: routeA, changedRouteB.id: changedRouteB],
            mutedRouteIDs: []
        )

        XCTAssertEqual(
            try XCTUnwrap(
                RealizationKey(
                    routeID: routeA.id,
                    intent: originalIntent,
                    observation: observation
                )
            ),
            try XCTUnwrap(
                RealizationKey(
                    routeID: routeA.id,
                    intent: changedIntent,
                    observation: observation
                )
            )
        )
    }

    func testAudioServerGenerationParticipatesInRealizationIdentity() {
        XCTAssertNotEqual(
            RealizationKey(
                routeID: "output-A",
                intent: AudioRouteTestFixtures.intent(),
                observation: AudioRouteTestFixtures.observation(server: 1)
            ),
            RealizationKey(
                routeID: "output-A",
                intent: AudioRouteTestFixtures.intent(),
                observation: AudioRouteTestFixtures.observation(server: 2)
            )
        )
    }
}
