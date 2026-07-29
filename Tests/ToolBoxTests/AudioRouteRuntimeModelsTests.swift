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
