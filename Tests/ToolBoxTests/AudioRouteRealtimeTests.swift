import XCTest
@testable import ToolBox

final class AudioRouteRealtimeTests: XCTestCase {
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

        XCTAssertEqual(output[0], 0.75, accuracy: 0.0001)
        XCTAssertEqual(output[2], 0.5, accuracy: 0.0001)
        XCTAssertEqual(output[4], 0.25, accuracy: 0.0001)
        XCTAssertEqual(output[6], 0, accuracy: 0.0001)
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

        XCTAssertEqual(output, source)
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
}
