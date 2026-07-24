import XCTest
@testable import ToolBox

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
        var samples: [Float] = [-1.5, -1, 0.25, 1, 2]

        let clipped = samples.withUnsafeMutableBufferPointer { buffer in
            TBAudioClamp(buffer.baseAddress, UInt32(buffer.count))
        }

        XCTAssertEqual(clipped, 2)
        XCTAssertEqual(samples, [-1, -1, 0.25, 1, 1])
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
