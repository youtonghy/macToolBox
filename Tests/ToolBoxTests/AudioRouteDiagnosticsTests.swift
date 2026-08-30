import XCTest
@testable import ToolBoxCore

final class AudioRouteDiagnosticsTests: XCTestCase {
    func testNoCallbacksRemainStartingDuringGracePeriod() {
        XCTAssertEqual(
            AudioRouteDiagnosticsEvaluator.evaluate(
                snapshot: nil,
                previous: nil,
                startupPollCount: 1,
                consecutiveOutputStalledPollCount: 0,
                consecutiveCaptureStalledPollCount: 0
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
                consecutiveOutputStalledPollCount: 0,
                consecutiveCaptureStalledPollCount: 0
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
                consecutiveOutputStalledPollCount: 8,
                consecutiveCaptureStalledPollCount: 8
            ),
            .stalled
        )
    }

    func testEitherCaptureOrOutputStoppingBecomesStalledWhileSourceProducesOutput() {
        let previous = snapshot(captureFrames: 512, outputFrames: 512)

        XCTAssertEqual(
            AudioRouteDiagnosticsEvaluator.evaluate(
                snapshot: snapshot(captureFrames: 512, outputFrames: 1024),
                previous: previous,
                startupPollCount: 20,
                consecutiveOutputStalledPollCount: 0,
                consecutiveCaptureStalledPollCount: 8,
                sourceIsProducingOutput: true
            ),
            .stalled
        )
        XCTAssertEqual(
            AudioRouteDiagnosticsEvaluator.evaluate(
                snapshot: snapshot(captureFrames: 1024, outputFrames: 512),
                previous: previous,
                startupPollCount: 20,
                consecutiveOutputStalledPollCount: 8,
                consecutiveCaptureStalledPollCount: 0,
                sourceIsProducingOutput: true
            ),
            .stalled
        )
    }

    func testFrozenCaptureStaysActiveBelowStallThreshold() {
        let previous = snapshot(captureFrames: 512, outputFrames: 512)

        XCTAssertEqual(
            AudioRouteDiagnosticsEvaluator.evaluate(
                snapshot: snapshot(captureFrames: 512, outputFrames: 1024),
                previous: previous,
                startupPollCount: 20,
                consecutiveOutputStalledPollCount: 0,
                consecutiveCaptureStalledPollCount: 7,
                sourceIsProducingOutput: true
            ),
            .active
        )
    }

    func testOutputNeverRenderingBecomesStalledAfterGraceAndStallWindow() {
        // Output IOProc dead from the very first callback while the source is
        // confirmed producing: a route the user can never hear through.
        XCTAssertEqual(
            AudioRouteDiagnosticsEvaluator.evaluate(
                snapshot: snapshot(captureFrames: 512, outputFrames: 0),
                previous: nil,
                startupPollCount: AudioRouteDiagnosticsEvaluator.startupGracePollCount
                    + AudioRouteDiagnosticsEvaluator.stallPollCount,
                consecutiveOutputStalledPollCount: 0,
                consecutiveCaptureStalledPollCount: 0,
                sourceIsProducingOutput: true
            ),
            .stalled
        )
        // Still inside the combined window it must not be torn down.
        XCTAssertEqual(
            AudioRouteDiagnosticsEvaluator.evaluate(
                snapshot: snapshot(captureFrames: 512, outputFrames: 0),
                previous: nil,
                startupPollCount: AudioRouteDiagnosticsEvaluator.startupGracePollCount
                    + AudioRouteDiagnosticsEvaluator.stallPollCount - 1,
                consecutiveOutputStalledPollCount: 0,
                consecutiveCaptureStalledPollCount: 0,
                sourceIsProducingOutput: true
            ),
            .awaitingAudio
        )
    }

    func testSilentCaptureForeverIsNotAStallWhenOutputRuns() {
        // DRM-protected content keeps the tap silent indefinitely; it must stay
        // `.awaitingAudio`, never be torn down, even long after every window.
        XCTAssertEqual(
            AudioRouteDiagnosticsEvaluator.evaluate(
                snapshot: snapshot(outputFrames: 2048),
                previous: snapshot(outputFrames: 1024),
                startupPollCount: 100,
                consecutiveOutputStalledPollCount: 0,
                consecutiveCaptureStalledPollCount: 100,
                sourceIsProducingOutput: true
            ),
            .awaitingAudio
        )
    }

    func testPausedSourceKeepsRouteInsteadOfStalling() {
        // Output IOProc keeps running while a paused app stops feeding the tap.
        // Releasing the route here would drop the saved per-app gain.
        XCTAssertEqual(
            AudioRouteDiagnosticsEvaluator.evaluate(
                snapshot: snapshot(captureFrames: 512, outputFrames: 1024),
                previous: snapshot(captureFrames: 512, outputFrames: 512),
                startupPollCount: 20,
                consecutiveOutputStalledPollCount: 0,
                consecutiveCaptureStalledPollCount: 8,
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
                consecutiveOutputStalledPollCount: 8,
                consecutiveCaptureStalledPollCount: 0,
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
                consecutiveOutputStalledPollCount: 8,
                consecutiveCaptureStalledPollCount: 8
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
            consecutiveOutputStalledPollCount: 0,
            consecutiveCaptureStalledPollCount: 0
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
