import XCTest
@testable import ToolBox

final class AudioRouteDiagnosticsTests: XCTestCase {
    func testNoCallbacksRemainStartingDuringGracePeriod() {
        XCTAssertEqual(
            AudioRouteDiagnosticsEvaluator.evaluate(
                snapshot: nil,
                previous: nil,
                startupPollCount: 1,
                consecutiveStalledPollCount: 0
            ),
            .starting
        )
    }

    func testNoCallbacksBecomeAwaitingAudioAfterGracePeriod() {
        XCTAssertEqual(
            AudioRouteDiagnosticsEvaluator.evaluate(
                snapshot: nil,
                previous: nil,
                startupPollCount: 8,
                consecutiveStalledPollCount: 0
            ),
            .awaitingAudio
        )
    }

    func testCaptureOnlyAndOutputOnlyCannotBecomeActive() {
        XCTAssertEqual(
            evaluate(snapshot: snapshot(captureFrames: 512), startupPollCount: 8),
            .awaitingAudio
        )
        XCTAssertEqual(
            evaluate(snapshot: snapshot(outputFrames: 512), startupPollCount: 8),
            .awaitingAudio
        )
    }

    func testCaptureAndOutputProgressBecomeActive() {
        XCTAssertEqual(
            evaluate(snapshot: snapshot(captureFrames: 512, outputFrames: 512)),
            .active
        )
    }

    func testFatalCallbackMismatchFailsImmediately() {
        XCTAssertEqual(
            evaluate(snapshot: snapshot(formatMismatchCount: 1, fatalCallbackMismatch: true)),
            .fatal(.callbackFormatMismatch)
        )
    }

    func testSourceOnlyFormatMismatchDoesNotFailSharedRoute() {
        // Multi-app routes share one diagnostics snapshot. A single unreadable
        // source (e.g. 小红书 iOS shell) must not tear down Zoom on the same device.
        XCTAssertEqual(
            evaluate(
                snapshot: snapshot(
                    captureFrames: 512,
                    outputFrames: 512,
                    formatMismatchCount: 3,
                    fatalCallbackMismatch: false
                )
            ),
            .active
        )
    }

    func testPreviouslyActiveRouteBecomesStalledAfterThreshold() {
        let value = snapshot(captureFrames: 512, outputFrames: 512)

        XCTAssertEqual(
            AudioRouteDiagnosticsEvaluator.evaluate(
                snapshot: value,
                previous: value,
                startupPollCount: 20,
                consecutiveStalledPollCount: 8
            ),
            .stalled
        )
    }

    func testEitherCaptureOrOutputStoppingBecomesStalledWhileSourceProducesOutput() {
        let previous = snapshot(captureFrames: 512, outputFrames: 512)

        for current in [
            snapshot(captureFrames: 512, outputFrames: 1024),
            snapshot(captureFrames: 1024, outputFrames: 512)
        ] {
            XCTAssertEqual(
                AudioRouteDiagnosticsEvaluator.evaluate(
                    snapshot: current,
                    previous: previous,
                    startupPollCount: 20,
                    consecutiveStalledPollCount: 8,
                    sourceIsProducingOutput: true
                ),
                .stalled
            )
        }
    }

    func testPausedSourceKeepsRouteInsteadOfStalling() {
        // Output IOProc keeps running while a paused app stops feeding the tap.
        // Releasing the route here would drop the saved per-app gain.
        XCTAssertEqual(
            AudioRouteDiagnosticsEvaluator.evaluate(
                snapshot: snapshot(captureFrames: 512, outputFrames: 1024),
                previous: snapshot(captureFrames: 512, outputFrames: 512),
                startupPollCount: 20,
                consecutiveStalledPollCount: 8,
                sourceIsProducingOutput: false
            ),
            .awaitingAudio
        )
    }

    func testDeadOutputIOProcStallsEvenWhileSourceIsIdle() {
        XCTAssertEqual(
            AudioRouteDiagnosticsEvaluator.evaluate(
                snapshot: snapshot(captureFrames: 1024, outputFrames: 512),
                previous: snapshot(captureFrames: 512, outputFrames: 512),
                startupPollCount: 20,
                consecutiveStalledPollCount: 8,
                sourceIsProducingOutput: false
            ),
            .stalled
        )
    }

    func testWrappingCountersStillCountAsProgress() {
        let previous = snapshot(captureFrames: .max, outputFrames: .max)
        let current = snapshot(captureFrames: 1, outputFrames: 1)

        XCTAssertEqual(
            AudioRouteDiagnosticsEvaluator.evaluate(
                snapshot: current,
                previous: previous,
                startupPollCount: 20,
                consecutiveStalledPollCount: 8
            ),
            .active
        )
    }

    func testAwaitingRouteRecoversWhenBothSidesProduceFrames() {
        XCTAssertEqual(
            evaluate(
                snapshot: snapshot(captureFrames: 1024, outputFrames: 1024),
                startupPollCount: 12
            ),
            .active
        )
    }

    private func evaluate(
        snapshot: AudioRouteDiagnosticsSnapshot,
        startupPollCount: Int = 1
    ) -> AudioRouteDiagnosticsHealth {
        AudioRouteDiagnosticsEvaluator.evaluate(
            snapshot: snapshot,
            previous: nil,
            startupPollCount: startupPollCount,
            consecutiveStalledPollCount: 0
        )
    }

    private func snapshot(
        captureFrames: UInt64 = 0,
        outputFrames: UInt64 = 0,
        formatMismatchCount: UInt64 = 0,
        fatalCallbackMismatch: Bool = false
    ) -> AudioRouteDiagnosticsSnapshot {
        AudioRouteDiagnosticsSnapshot(
            routeID: "speakers",
            generation: 1,
            captureCallbackCount: captureFrames == 0 ? 0 : 1,
            captureFrameCount: captureFrames,
            outputCallbackCount: outputFrames == 0 ? 0 : 1,
            outputFrameCount: outputFrames,
            formatMismatchCount: formatMismatchCount,
            fatalCallbackMismatch: fatalCallbackMismatch
        )
    }
}
