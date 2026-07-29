import XCTest
@testable import ToolBox

final class AudioRouteHealthEvaluatorTests: XCTestCase {
    func testFormatMismatchRequestsImmediateSourceRebuild() {
        let decision = AudioRouteHealthEvaluator.evaluate(
            current: AudioRouteTestFixtures.healthSample(formatMismatchCount: 1),
            previous: AudioRouteTestFixtures.healthSample(),
            consecutiveStalledTickCount: 0,
            consecutiveNonFiniteTickCount: 0,
            consecutiveOverloadWindowCount: 0
        )

        XCTAssertEqual(decision, .rebuild(.formatContractViolation))
    }

    func testTwoStalledTicksRequestRebuild() {
        XCTAssertEqual(
            evaluate(consecutiveStalledTickCount: 1),
            .degraded(.callbackStall)
        )
        XCTAssertEqual(
            evaluate(consecutiveStalledTickCount: 2),
            .rebuild(.callbackStall)
        )
    }

    func testTwoNonFiniteTicksRequestRebuild() {
        let current = AudioRouteTestFixtures.healthSample(nonFiniteSampleCount: 1)

        XCTAssertEqual(
            evaluate(current: current, consecutiveNonFiniteTickCount: 1),
            .degraded(.nonFiniteInput)
        )
        XCTAssertEqual(
            evaluate(current: current, consecutiveNonFiniteTickCount: 2),
            .rebuild(.nonFiniteInput)
        )
    }

    func testRepeatedRingOverloadRequestsRebuild() {
        let current = AudioRouteTestFixtures.healthSample(underrunFrameCount: 513)

        XCTAssertEqual(
            evaluate(current: current, consecutiveOverloadWindowCount: 1),
            .degraded(.ringOverload)
        )
        XCTAssertEqual(
            evaluate(current: current, consecutiveOverloadWindowCount: 2),
            .rebuild(.ringOverload)
        )
    }

    func testForcedResyncBurstDegradesThenRebuildsAcrossTwoWindows() {
        let current = AudioRouteTestFixtures.healthSample(forcedResyncCount: 2)

        XCTAssertEqual(
            evaluate(current: current, consecutiveOverloadWindowCount: 1),
            .degraded(.forcedResyncBurst)
        )
        XCTAssertEqual(
            evaluate(current: current, consecutiveOverloadWindowCount: 2),
            .rebuild(.forcedResyncBurst)
        )
    }

    func testClippingNeverRequestsTopologyRebuild() {
        XCTAssertEqual(
            evaluate(
                current: AudioRouteTestFixtures.healthSample(clippedSampleCount: 20_000)
            ),
            .observe(.clipping)
        )
    }

    func testPausedSourceWithProgressingOutputIsHealthy() {
        XCTAssertEqual(
            evaluate(
                current: AudioRouteTestFixtures.healthSample(
                    outputFrameCount: 256,
                    sourceIsProducingOutput: false
                ),
                consecutiveStalledTickCount: 2
            ),
            .healthy
        )
    }

    func testWrappingCountersUseWrappingSubtraction() {
        XCTAssertEqual(
            evaluate(
                current: AudioRouteTestFixtures.healthSample(
                    captureFrameCount: 1,
                    outputFrameCount: 1,
                    clippedSampleCount: 1
                ),
                previous: AudioRouteTestFixtures.healthSample(
                    captureFrameCount: .max,
                    outputFrameCount: .max,
                    clippedSampleCount: .max
                )
            ),
            .observe(.clipping)
        )
    }

    private func evaluate(
        current: AudioRouteHealthSample = AudioRouteTestFixtures.healthSample(),
        previous: AudioRouteHealthSample = AudioRouteTestFixtures.healthSample(),
        consecutiveStalledTickCount: Int = 0,
        consecutiveNonFiniteTickCount: Int = 0,
        consecutiveOverloadWindowCount: Int = 0
    ) -> AudioRouteHealthDecision {
        AudioRouteHealthEvaluator.evaluate(
            current: current,
            previous: previous,
            consecutiveStalledTickCount: consecutiveStalledTickCount,
            consecutiveNonFiniteTickCount: consecutiveNonFiniteTickCount,
            consecutiveOverloadWindowCount: consecutiveOverloadWindowCount
        )
    }
}
