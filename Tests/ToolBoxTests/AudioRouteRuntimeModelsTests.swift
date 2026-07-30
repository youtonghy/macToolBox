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
