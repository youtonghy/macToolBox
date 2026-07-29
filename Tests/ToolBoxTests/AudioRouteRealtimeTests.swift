import CoreAudio
import XCTest
@testable import ToolBox

final class AudioRouteRealtimeTests: XCTestCase {
    private enum KernelCreationError: Error {
        case rejectedFormat
    }

    func testKernelAcceptsOnlyTheExistingClockDriftBudget() throws {
        let compatible = try makeKernel(
            generation: 7,
            sourceCount: 1,
            sourceSampleRate: 47_952,
            outputSampleRate: 48_000
        )
        TBAudioRealtimeKernelDestroy(compatible)

        XCTAssertThrowsError(
            try makeKernel(
                generation: 7,
                sourceCount: 1,
                sourceSampleRate: 47_951,
                outputSampleRate: 48_000
            )
        )
    }

    func testStaleGenerationCaptureIsRejected() throws {
        let kernel = try makeKernel(generation: 7, sourceCount: 1)
        defer { TBAudioRealtimeKernelDestroy(kernel) }

        XCTAssertFalse(pushStereo(kernel, generation: 6, source: 0, value: 1))
        XCTAssertEqual(
            renderStereo(kernel, generation: 7, frames: 4),
            [Float](repeating: 0, count: 8)
        )
    }

    func testStaleGenerationOutputIsRejectedAndZeroed() throws {
        let kernel = try makeKernel(generation: 7, sourceCount: 1)
        defer { TBAudioRealtimeKernelDestroy(kernel) }

        XCTAssertTrue(pushStereo(kernel, generation: 7, source: 0, value: 0.75))
        XCTAssertEqual(
            renderStereo(kernel, generation: 6, frames: 4, expectedSuccess: false),
            [Float](repeating: 0, count: 8)
        )
    }

    func testMutingOneSourceKeepsSiblingAudible() throws {
        let kernel = try makeKernel(generation: 7, sourceCount: 2)
        defer { TBAudioRealtimeKernelDestroy(kernel) }

        XCTAssertTrue(pushStereo(kernel, generation: 7, source: 0, value: 0.25))
        XCTAssertTrue(pushStereo(kernel, generation: 7, source: 1, value: 0.50))
        TBAudioRealtimeKernelBeginSourceMute(kernel, 0, 0)

        XCTAssertEqual(
            renderStereo(kernel, generation: 7, frames: 4),
            [Float](repeating: 0.50, count: 8)
        )
    }

    func testZeroFrameCallbacksAreAcceptedAsNoOp() throws {
        let kernel = try makeKernel(generation: 7, sourceCount: 1)
        defer { TBAudioRealtimeKernelDestroy(kernel) }

        var inputSample: Float = 1
        withUnsafePointer(to: &inputSample) { pointer in
            var input = TBAudioRealtimeInputView(
                buffers: (UnsafeRawPointer(pointer), nil, nil, nil, nil, nil, nil, nil),
                byteSizes: (0, 0, 0, 0, 0, 0, 0, 0),
                bufferCount: 1,
                frameCount: 0
            )
            XCTAssertTrue(TBAudioRealtimeKernelPushCapture(kernel, 7, 0, &input))
        }

        var outputSample: Float = -1
        withUnsafeMutablePointer(to: &outputSample) { pointer in
            var output = TBAudioRealtimeOutputView(
                buffers: (UnsafeMutableRawPointer(pointer), nil, nil, nil, nil, nil, nil, nil),
                byteSizes: (0, 0, 0, 0, 0, 0, 0, 0),
                bufferCount: 1,
                frameCount: 0
            )
            XCTAssertTrue(TBAudioRealtimeKernelRenderOutput(kernel, 7, &output))
        }
        XCTAssertEqual(outputSample, -1)
    }

    func testDetachedKernelRejectsLateCallbacksAndZeroesOutput() throws {
        let kernel = try makeKernel(generation: 7, sourceCount: 1)
        defer { TBAudioRealtimeKernelDestroy(kernel) }

        XCTAssertTrue(pushStereo(kernel, generation: 7, source: 0, value: 0.75))
        TBAudioRealtimeKernelDetach(kernel)

        XCTAssertFalse(pushStereo(kernel, generation: 7, source: 0, value: 1))
        XCTAssertEqual(
            renderStereo(kernel, generation: 7, frames: 4, expectedSuccess: false),
            [Float](repeating: 0, count: 8)
        )
        XCTAssertEqual(try snapshot(kernel).rejectedGenerationCount, 2)
    }

    func testMalformedCaptureIsIsolatedAndCounted() throws {
        let kernel = try makeKernel(generation: 7, sourceCount: 1)
        defer { TBAudioRealtimeKernelDestroy(kernel) }

        var sample: Float = 1
        withUnsafePointer(to: &sample) { pointer in
            var input = TBAudioRealtimeInputView(
                buffers: (UnsafeRawPointer(pointer), nil, nil, nil, nil, nil, nil, nil),
                byteSizes: (4, 0, 0, 0, 0, 0, 0, 0),
                bufferCount: 1,
                frameCount: 4
            )
            XCTAssertFalse(TBAudioRealtimeKernelPushCapture(kernel, 7, 0, &input))
        }

        let value = try snapshot(kernel)
        XCTAssertEqual(value.formatMismatchCount, 1)
        XCTAssertEqual(value.sourceFatalCount, 1)
    }

    func testMalformedOutputBuffersAreZeroedAndCounted() throws {
        let kernel = try makeKernel(generation: 7, sourceCount: 1)
        defer { TBAudioRealtimeKernelDestroy(kernel) }

        var left = [Float](repeating: 1, count: 4)
        var right = [Float](repeating: 1, count: 4)
        left.withUnsafeMutableBytes { leftBytes in
            right.withUnsafeMutableBytes { rightBytes in
                var output = TBAudioRealtimeOutputView(
                    buffers: (
                        leftBytes.baseAddress, rightBytes.baseAddress,
                        nil, nil, nil, nil, nil, nil
                    ),
                    byteSizes: (
                        UInt32(leftBytes.count), UInt32(rightBytes.count),
                        0, 0, 0, 0, 0, 0
                    ),
                    bufferCount: 2,
                    frameCount: 4
                )
                XCTAssertFalse(TBAudioRealtimeKernelRenderOutput(kernel, 7, &output))
            }
        }

        XCTAssertEqual(left, [Float](repeating: 0, count: 4))
        XCTAssertEqual(right, [Float](repeating: 0, count: 4))
        XCTAssertEqual(try snapshot(kernel).formatMismatchCount, 1)
    }

    func testSnapshotReportsAcceptedCallbackAndFrameCounts() throws {
        let kernel = try makeKernel(generation: 7, sourceCount: 1)
        defer { TBAudioRealtimeKernelDestroy(kernel) }

        XCTAssertTrue(pushStereo(kernel, generation: 7, source: 0, value: 0.25))
        _ = renderStereo(kernel, generation: 7, frames: 4)

        let value = try snapshot(kernel)
        XCTAssertEqual(value.captureCallbackCount, 1)
        XCTAssertEqual(value.captureFrameCount, 4)
        XCTAssertEqual(value.outputCallbackCount, 1)
        XCTAssertEqual(value.outputFrameCount, 4)
    }

    func testTargetLatencyIsBoundedByCallbackPeriods() {
        XCTAssertEqual(TBAudioRecommendedTargetFrames(128, 0, 0), 256)
        XCTAssertEqual(TBAudioRecommendedTargetFrames(512, 64, 32), 1120)
        XCTAssertEqual(TBAudioRecommendedTargetFrames(4096, 1024, 1024), 2048)
    }

    func testHighWaterResyncDropsStaleAudioAndReportsIt() throws {
        let state = try XCTUnwrap(TBAudioRealtimeTestCreate(8, 32, 1))
        defer { TBAudioRealtimeTestDestroy(state) }
        let source = (0..<48).map(Float.init)
        source.withUnsafeBufferPointer {
            TBAudioRealtimeTestWrite(state, $0.baseAddress, 24)
        }

        var first = [Float](repeating: 0, count: 8)
        first.withUnsafeMutableBufferPointer {
            TBAudioRealtimeTestMix(state, $0.baseAddress, 4, 1)
        }
        var second = [Float](repeating: 0, count: 8)
        second.withUnsafeMutableBufferPointer {
            TBAudioRealtimeTestMix(state, $0.baseAddress, 4, 1)
        }

        let retainedSampleCount = first.count * 2
        let retainedStart = source.count - retainedSampleCount

        XCTAssertEqual(TBAudioRealtimeTestForcedResyncCount(state), 1)
        XCTAssertEqual(TBAudioRealtimeTestUnderrunFrames(state), 0)
        XCTAssertEqual(first, Array(source[retainedStart..<(retainedStart + first.count)]))
        XCTAssertEqual(second.first, source[retainedStart + first.count])
        XCTAssertEqual(
            try XCTUnwrap(second.last),
            try XCTUnwrap(source.last),
            accuracy: 0.001
        )
    }

    func testGainChangesRampInsteadOfStepping() throws {
        let state = try XCTUnwrap(TBAudioRealtimeTestCreate(4, 32, 4))
        defer { TBAudioRealtimeTestDestroy(state) }
        let source = [Float](repeating: 1, count: 16)
        source.withUnsafeBufferPointer {
            TBAudioRealtimeTestWrite(state, $0.baseAddress, 8)
        }

        var output = [Float](repeating: 0, count: 8)
        output.withUnsafeMutableBufferPointer {
            TBAudioRealtimeTestMix(state, $0.baseAddress, 4, 0)
        }

        // After fix: recoveryGain starts at 0 and ramps up over gainRampFrames (4).
        // Frame 0: recoveryGain = 0/4, targetGain ramps from 1 toward 0
        // Frame 1: recoveryGain = 1/4, targetGain continues ramping
        // Frame 2: recoveryGain = 2/4, targetGain continues
        // Frame 3: recoveryGain = 3/4, targetGain reaches 0
        // Each output sample = source * currentGain * recoveryGain
        XCTAssertEqual(output[0], 0.1875, accuracy: 0.0001)  // ≈ 1 * 0.75 * 0.25
        XCTAssertEqual(output[2], 0.25, accuracy: 0.0001)    // ≈ 1 * 0.5 * 0.5
        XCTAssertEqual(output[4], 0.1875, accuracy: 0.0001)  // ≈ 1 * 0.25 * 0.75
        XCTAssertEqual(output[6], 0, accuracy: 0.0001)       // 1 * 0 * 1
    }

    func testExactCallbackOfAvailableFramesDoesNotUnderrun() throws {
        let state = try XCTUnwrap(TBAudioRealtimeTestCreate(4, 32, 4))
        defer { TBAudioRealtimeTestDestroy(state) }
        let source = [Float](repeating: 0.5, count: 8)
        source.withUnsafeBufferPointer {
            TBAudioRealtimeTestWrite(state, $0.baseAddress, 4)
        }

        var output = [Float](repeating: 0, count: 8)
        output.withUnsafeMutableBufferPointer {
            TBAudioRealtimeTestMix(state, $0.baseAddress, 4, 1)
        }

        // After fix: recoveryGain starts at 0 and fades in over 4 frames.
        // Output = source * targetGain * recoveryGain
        // Frame 0: 0.5 * 1 * 0.25 = 0.125
        // Frame 1: 0.5 * 1 * 0.5  = 0.25
        // Frame 2: 0.5 * 1 * 0.75 = 0.375
        // Frame 3: 0.5 * 1 * 1.0  = 0.5
        XCTAssertEqual(output, [0.125, 0.125, 0.25, 0.25, 0.375, 0.375, 0.5, 0.5])
    }

    func testLargeCallbackKeepsItsOwnFramesWhenTargetIsLower() throws {
        let frameCount = 4_096
        let state = try XCTUnwrap(TBAudioRealtimeTestCreate(2_048, 16_384, 1))
        defer { TBAudioRealtimeTestDestroy(state) }
        let source = [Float](repeating: 0.5, count: frameCount * 2)
        source.withUnsafeBufferPointer {
            TBAudioRealtimeTestWrite(state, $0.baseAddress, UInt32(frameCount))
        }

        var output = [Float](repeating: 0, count: frameCount * 2)
        output.withUnsafeMutableBufferPointer {
            TBAudioRealtimeTestMix(state, $0.baseAddress, UInt32(frameCount), 1)
        }

        XCTAssertEqual(TBAudioRealtimeTestUnderrunFrames(state), 0)
        XCTAssertTrue(output.allSatisfy { $0 == 0.5 })
    }

    func testLargeCallbackKeepsTwoBufferedCallbacksBeforeResync() throws {
        let outputFrames = 4_096
        let state = try XCTUnwrap(TBAudioRealtimeTestCreate(2_048, 16_384, 1))
        defer { TBAudioRealtimeTestDestroy(state) }
        let source = (0..<(outputFrames * 4)).map(Float.init)
        source.withUnsafeBufferPointer {
            TBAudioRealtimeTestWrite(state, $0.baseAddress, UInt32(outputFrames * 2))
        }

        var first = [Float](repeating: 0, count: outputFrames * 2)
        first.withUnsafeMutableBufferPointer {
            TBAudioRealtimeTestMix(state, $0.baseAddress, UInt32(outputFrames), 1)
        }
        var second = [Float](repeating: 0, count: outputFrames * 2)
        second.withUnsafeMutableBufferPointer {
            TBAudioRealtimeTestMix(state, $0.baseAddress, UInt32(outputFrames), 1)
        }

        XCTAssertEqual(TBAudioRealtimeTestForcedResyncCount(state), 0)
        XCTAssertEqual(TBAudioRealtimeTestUnderrunFrames(state), 0)
        XCTAssertEqual(first, Array(source[..<first.count]))
        XCTAssertEqual(second, Array(source[first.count...]))
    }

    func testLargeCallbackHighWaterResyncKeepsTwoCallbackPeriods() throws {
        let outputFrames = 4_096
        let state = try XCTUnwrap(TBAudioRealtimeTestCreate(2_048, 16_384, 1))
        defer { TBAudioRealtimeTestDestroy(state) }
        let source = (0..<(outputFrames * 6)).map(Float.init)
        source.withUnsafeBufferPointer {
            TBAudioRealtimeTestWrite(state, $0.baseAddress, UInt32(outputFrames * 3))
        }

        var first = [Float](repeating: 0, count: outputFrames * 2)
        first.withUnsafeMutableBufferPointer {
            TBAudioRealtimeTestMix(state, $0.baseAddress, UInt32(outputFrames), 1)
        }
        var second = [Float](repeating: 0, count: outputFrames * 2)
        second.withUnsafeMutableBufferPointer {
            TBAudioRealtimeTestMix(state, $0.baseAddress, UInt32(outputFrames), 1)
        }

        let retainedSampleCount = first.count * 2
        let retainedStart = source.count - retainedSampleCount

        XCTAssertEqual(TBAudioRealtimeTestForcedResyncCount(state), 1)
        XCTAssertEqual(TBAudioRealtimeTestUnderrunFrames(state), 0)
        XCTAssertEqual(first, Array(source[retainedStart..<(retainedStart + first.count)]))
        XCTAssertEqual(second, Array(source[(retainedStart + first.count)...]))
    }

    func testMatchingBatchesDoNotDriftPastAvailableInput() throws {
        let frameCount = 2_048
        let state = try XCTUnwrap(TBAudioRealtimeTestCreate(2_048, 16_384, 1))
        defer { TBAudioRealtimeTestDestroy(state) }
        let source = (0..<(frameCount * 4)).map(Float.init)
        source.withUnsafeBufferPointer {
            TBAudioRealtimeTestWrite(state, $0.baseAddress, UInt32(frameCount * 2))
        }

        var first = [Float](repeating: 0, count: frameCount * 2)
        first.withUnsafeMutableBufferPointer {
            TBAudioRealtimeTestMix(state, $0.baseAddress, UInt32(frameCount), 1)
        }
        var second = [Float](repeating: 0, count: frameCount * 2)
        second.withUnsafeMutableBufferPointer {
            TBAudioRealtimeTestMix(state, $0.baseAddress, UInt32(frameCount), 1)
        }

        XCTAssertEqual(TBAudioRealtimeTestUnderrunFrames(state), 0)
        XCTAssertEqual(first[first.count / 2], source[first.count / 2])
        XCTAssertEqual(first.last, source[first.count - 1])
        XCTAssertEqual(second.first, source[first.count])
        XCTAssertEqual(second.last, source.last)
    }

    func testRingWrapsRepeatedlyWithoutDroppingOrReorderingFrames() throws {
        let state = try XCTUnwrap(TBAudioRealtimeTestCreate(4, 8, 1))
        defer { TBAudioRealtimeTestDestroy(state) }

        for cycle in 0..<10_000 {
            let value = Float(cycle % 97) / 97
            let source = [Float](repeating: value, count: 8)
            source.withUnsafeBufferPointer {
                TBAudioRealtimeTestWrite(state, $0.baseAddress, 4)
            }
            var output = [Float](repeating: 0, count: 8)
            output.withUnsafeMutableBufferPointer {
                TBAudioRealtimeTestMix(state, $0.baseAddress, 4, 1)
            }
            XCTAssertEqual(output, source)
        }

        XCTAssertEqual(TBAudioRealtimeTestOccupancyFrames(state), 0)
        XCTAssertEqual(TBAudioRealtimeTestDroppedFrames(state), 0)
        XCTAssertEqual(TBAudioRealtimeTestUnderrunFrames(state), 0)
    }

    func testOverflowDropsNewestFramesAndReportsExactCount() throws {
        let state = try XCTUnwrap(TBAudioRealtimeTestCreate(4, 8, 1))
        defer { TBAudioRealtimeTestDestroy(state) }
        let source = (0..<24).map(Float.init)
        source.withUnsafeBufferPointer {
            TBAudioRealtimeTestWrite(state, $0.baseAddress, 12)
        }

        XCTAssertEqual(TBAudioRealtimeTestOccupancyFrames(state), 8)
        XCTAssertEqual(TBAudioRealtimeTestHighWaterFrames(state), 8)
        XCTAssertEqual(TBAudioRealtimeTestDroppedFrames(state), 4)
    }

    func testUnderrunRecoveryFadesBackIn() throws {
        let state = try XCTUnwrap(TBAudioRealtimeTestCreate(4, 32, 4))
        defer { TBAudioRealtimeTestDestroy(state) }
        let source = [Float](repeating: 1, count: 8)
        source.withUnsafeBufferPointer {
            TBAudioRealtimeTestWrite(state, $0.baseAddress, 4)
        }
        var first = [Float](repeating: 0, count: 8)
        first.withUnsafeMutableBufferPointer {
            TBAudioRealtimeTestMix(state, $0.baseAddress, 4, 1)
        }

        var underrun = [Float](repeating: 0, count: 8)
        underrun.withUnsafeMutableBufferPointer {
            TBAudioRealtimeTestMix(state, $0.baseAddress, 4, 1)
        }
        XCTAssertEqual(TBAudioRealtimeTestUnderrunFrames(state), 4)
        XCTAssertEqual(underrun, [Float](repeating: 0, count: 8))

        source.withUnsafeBufferPointer {
            TBAudioRealtimeTestWrite(state, $0.baseAddress, 4)
        }
        var recovered = [Float](repeating: 0, count: 8)
        recovered.withUnsafeMutableBufferPointer {
            TBAudioRealtimeTestMix(state, $0.baseAddress, 4, 1)
        }
        XCTAssertEqual([recovered[0], recovered[2], recovered[4], recovered[6]], [0.25, 0.5, 0.75, 1])
    }

    func testNonFiniteSamplesAreReplacedWithSilenceAndReported() throws {
        let state = try XCTUnwrap(TBAudioRealtimeTestCreate(4, 32, 1))
        defer { TBAudioRealtimeTestDestroy(state) }
        let source: [Float] = [0.5, .nan, .infinity, -.infinity, -0.5, 0.25, 1, -1]
        source.withUnsafeBufferPointer {
            TBAudioRealtimeTestWrite(state, $0.baseAddress, 4)
        }
        var output = [Float](repeating: 0, count: 8)
        output.withUnsafeMutableBufferPointer {
            TBAudioRealtimeTestMix(state, $0.baseAddress, 4, 1)
        }

        XCTAssertEqual(output, [0.5, 0, 0, 0, -0.5, 0.25, 1, -1])
        XCTAssertTrue(output.allSatisfy(\.isFinite))
        XCTAssertEqual(TBAudioRealtimeTestNonFiniteSamples(state), 3)
    }

    func testNonFiniteTargetGainFailsClosedToSilence() throws {
        for gain in [Float.nan, .infinity, -.infinity] {
            let state = try XCTUnwrap(TBAudioRealtimeTestCreate(4, 32, 1))
            defer { TBAudioRealtimeTestDestroy(state) }
            let source = [Float](repeating: 1, count: 8)
            source.withUnsafeBufferPointer {
                TBAudioRealtimeTestWrite(state, $0.baseAddress, 4)
            }
            var output = [Float](repeating: 0, count: 8)
            output.withUnsafeMutableBufferPointer {
                TBAudioRealtimeTestMix(state, $0.baseAddress, 4, gain)
            }

            XCTAssertEqual(output, [Float](repeating: 0, count: 8))
            XCTAssertTrue(output.allSatisfy(\.isFinite))
        }
    }

    private func makeKernel(
        generation: UInt64,
        sourceCount: UInt32,
        sourceSampleRate: Double = 48_000,
        outputSampleRate: Double = 48_000
    ) throws -> OpaquePointer {
        let sourceFormat = TBAudioRealtimeFormat(
            sampleRate: sourceSampleRate,
            formatID: kAudioFormatLinearPCM,
            formatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            bytesPerFrame: 8,
            channelsPerFrame: 2,
            bitsPerChannel: 32
        )
        let outputFormat = TBAudioRealtimeFormat(
            sampleRate: outputSampleRate,
            formatID: kAudioFormatLinearPCM,
            formatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            bytesPerFrame: 8,
            channelsPerFrame: 2,
            bitsPerChannel: 32
        )
        let formats = [TBAudioRealtimeFormat](
            repeating: sourceFormat, count: Int(sourceCount)
        )
        return try formats.withUnsafeBufferPointer { pointer in
            guard let kernel = TBAudioRealtimeKernelCreate(
                generation,
                pointer.baseAddress!,
                sourceCount,
                outputFormat,
                4,
                32,
                1
            ) else {
                throw KernelCreationError.rejectedFormat
            }
            return kernel
        }
    }

    private func pushStereo(
        _ kernel: OpaquePointer,
        generation: UInt64,
        source: UInt32,
        value: Float
    ) -> Bool {
        let samples = [Float](repeating: value, count: 8)
        return samples.withUnsafeBytes { bytes in
            var view = TBAudioRealtimeInputView(
                buffers: (bytes.baseAddress, nil, nil, nil, nil, nil, nil, nil),
                byteSizes: (UInt32(bytes.count), 0, 0, 0, 0, 0, 0, 0),
                bufferCount: 1,
                frameCount: 4
            )
            return TBAudioRealtimeKernelPushCapture(
                kernel,
                generation,
                source,
                &view
            )
        }
    }

    private func renderStereo(
        _ kernel: OpaquePointer,
        generation: UInt64,
        frames: UInt32,
        expectedSuccess: Bool = true
    ) -> [Float] {
        var samples = [Float](repeating: -1, count: Int(frames * 2))
        samples.withUnsafeMutableBytes { bytes in
            var view = TBAudioRealtimeOutputView(
                buffers: (bytes.baseAddress, nil, nil, nil, nil, nil, nil, nil),
                byteSizes: (UInt32(bytes.count), 0, 0, 0, 0, 0, 0, 0),
                bufferCount: 1,
                frameCount: frames
            )
            XCTAssertEqual(
                TBAudioRealtimeKernelRenderOutput(kernel, generation, &view),
                expectedSuccess
            )
        }
        return samples
    }

    private func snapshot(_ kernel: OpaquePointer) throws -> TBAudioRealtimeSnapshot {
        var value = TBAudioRealtimeSnapshot()
        XCTAssertTrue(TBAudioRealtimeKernelCopySnapshot(kernel, &value))
        return value
    }
}
