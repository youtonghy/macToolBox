import XCTest
@testable import ToolBoxCore

final class AudioRouteDSPTests: XCTestCase {
    func testGainSupportsZeroNativeAndThreeHundredPercent() {
        let source: [Float] = [0.25, -0.5]
        for (gain, expected) in [(Float(0), [Float(0), 0]), (1, [0.25, -0.5]), (3, [0.75, -1.5])] {
            var output = [Float](repeating: 9, count: source.count)
            source.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer { destination in
                    TBAudioApplyGain(destination.baseAddress, input.baseAddress, UInt32(source.count), gain)
                }
            }
            XCTAssertEqual(output, expected)
        }
    }

    func testMixAddsSourcesAndReportsSamplesOutsideUnitRange() {
        var output: [Float] = [0.8, -0.8]
        let source: [Float] = [0.4, -0.4]
        let clipped = source.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { destination in
                TBAudioMixGain(destination.baseAddress, input.baseAddress, UInt32(source.count), 1)
            }
        }

        XCTAssertEqual(clipped, 2)
        XCTAssertEqual(output[0], 1.2, accuracy: 0.0001)
        XCTAssertEqual(output[1], -1.2, accuracy: 0.0001)
    }

    func testClampProtectsHardwareOutputRange() {
        // Below the soft-knee threshold the signal is unity (unchanged); above it a
        // smooth limiter keeps every sample strictly inside [-1, 1] while preserving
        // sign, instead of the previous hard clamp that produced harsh clipping.
        var samples: [Float] = [-1.5, -1, -0.9, 0.25, 0.9, 1, 2]

        let limiting = samples.withUnsafeMutableBufferPointer { buffer in
            TBAudioClamp(buffer.baseAddress, UInt32(buffer.count))
        }

        // Unity region passes through untouched.
        XCTAssertEqual(samples[2], -0.9, accuracy: 0.0001)   // at -threshold
        XCTAssertEqual(samples[3], 0.25, accuracy: 0.0001)   // well below threshold
        XCTAssertEqual(samples[4], 0.9, accuracy: 0.0001)    // at +threshold
        // Limited region stays bounded, monotonic, and sign-correct.
        XCTAssertTrue(samples.allSatisfy { $0 >= -1.0 && $0 <= 1.0 })
        XCTAssertLessThan(samples[0], -0.9)   // -1.5 pulled up but still negative, near -1
        XCTAssertGreaterThan(samples[0], -1.01)
        XCTAssertLessThan(samples[6], 1.0)    // 2.0 limited, strictly below +1
        XCTAssertGreaterThan(samples[6], 0.9)
        // Soft-knee is monotonic: a larger input never yields a smaller |output|.
        XCTAssertLessThan(abs(samples[0]), abs(samples[6]))  // |-1.5 out| < |2 out|
        // Every sample above the threshold counts as limited for diagnostics.
        XCTAssertEqual(limiting, 4)
    }

    func testClampReplacesNonFiniteHardwareSamplesWithSilence() {
        var samples: [Float] = [.nan, .infinity, -.infinity, 0.5]

        let sanitized = samples.withUnsafeMutableBufferPointer { buffer in
            TBAudioClamp(buffer.baseAddress, UInt32(buffer.count))
        }

        XCTAssertEqual(sanitized, 3)
        XCTAssertEqual(samples, [0, 0, 0, 0.5])
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
    }
}
