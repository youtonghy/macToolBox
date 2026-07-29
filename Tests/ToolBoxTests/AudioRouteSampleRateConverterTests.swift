import AudioToolbox
import XCTest

@testable import ToolBox

final class AudioRouteSampleRateConverterTests: XCTestCase {
    func testEqualRatePathBypassesAudioConverterAndDeinterleavesStereo() throws {
        let samples: [Float] = [0.1, -0.1, 0.2, -0.2, 0.3, -0.3, 0.4, -0.4]
        let result = try convert(
            samples,
            channels: 2,
            sourceRate: 48_000,
            destinationRate: 48_000
        )

        XCTAssertTrue(result.isBypass)
        XCTAssertEqual(result.left, [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(result.right, [-0.1, -0.2, -0.3, -0.4])
    }

    func testEqualRateMonoIsDuplicatedToBothCanonicalChannels() throws {
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4]
        let result = try convert(
            samples,
            channels: 1,
            sourceRate: 48_000,
            destinationRate: 48_000
        )

        XCTAssertEqual(result.left, samples)
        XCTAssertEqual(result.right, samples)
    }

    func testCrossRate997HertzToneMeetsSNRAndTHDNTargets() throws {
        for (sourceRate, destinationRate) in [
            (44_100.0, 48_000.0),
            (48_000.0, 44_100.0),
            (48_000.0, 96_000.0),
            (96_000.0, 48_000.0),
        ] {
            let source = sine(frequency: 997, sampleRate: sourceRate, duration: 1.5)
            let result = try convert(
                source,
                channels: 1,
                sourceRate: sourceRate,
                destinationRate: destinationRate
            )
            let metrics = toneMetrics(
                samples: result.left,
                frequency: 997,
                sampleRate: destinationRate
            )

            XCTAssertGreaterThanOrEqual(
                metrics.snrDB,
                90,
                "\(sourceRate) -> \(destinationRate) SNR"
            )
            XCTAssertLessThanOrEqual(
                metrics.thdNDB,
                -90,
                "\(sourceRate) -> \(destinationRate) THD+N"
            )
        }
    }

    func testPassbandRippleStaysWithinPointOneDecibel() throws {
        for (sourceRate, destinationRate) in [
            (44_100.0, 48_000.0),
            (48_000.0, 44_100.0),
            (48_000.0, 96_000.0),
            (96_000.0, 48_000.0),
        ] {
            let nyquist = min(sourceRate, destinationRate) / 2
            let frequencies = [200.0, 997.0, min(8_000, nyquist * 0.5), nyquist * 0.8]
            let levels = try frequencies.map { frequency in
                let source = sine(
                    frequency: frequency,
                    sampleRate: sourceRate,
                    duration: 1
                )
                let result = try convert(
                    source,
                    channels: 1,
                    sourceRate: sourceRate,
                    destinationRate: destinationRate
                )
                return toneMetrics(
                    samples: result.left,
                    frequency: frequency,
                    sampleRate: destinationRate
                ).levelDB
            }
            let ripple = try XCTUnwrap(levels.max()) - XCTUnwrap(levels.min())
            XCTAssertLessThanOrEqual(
                ripple,
                0.1,
                "\(sourceRate) -> \(destinationRate) ripple"
            )
        }
    }

    func testDownsamplingRejectsOutOfBandAlias() throws {
        let source = sine(frequency: 30_000, sampleRate: 96_000, duration: 1)
        let result = try convert(
            source,
            channels: 1,
            sourceRate: 96_000,
            destinationRate: 48_000
        )
        let trimmed = stableSamples(result.left)
        let rms = sqrt(trimmed.reduce(0.0) { $0 + Double($1 * $1) } / Double(trimmed.count))
        let aliasDBFS = 20 * log10(max(rms, Double.leastNonzeroMagnitude))

        XCTAssertLessThanOrEqual(aliasDBFS, -80)
    }

    func testSmallRealtimeChunksDoNotAccumulateFrameLoss() throws {
        let sourceRate = 44_100.0
        let destinationRate = 48_000.0
        let source = sine(frequency: 997, sampleRate: sourceRate, duration: 1.5)
        let output = try convertChunks(
            source,
            chunkFrames: 128,
            sourceRate: sourceRate,
            destinationRate: destinationRate
        )

        XCTAssertEqual(output.count, 72_000, accuracy: 1)
        XCTAssertGreaterThanOrEqual(
            toneMetrics(samples: output, frequency: 997, sampleRate: destinationRate).snrDB,
            90
        )
    }

    func testFirstCallbackStartsFromFreshConverterState() throws {
        let result = try convert(
            [Float](repeating: 0, count: 128),
            channels: 1,
            sourceRate: 48_000,
            destinationRate: 44_100
        )

        XCTAssertEqual(result.left.count, 117)
    }

    func testSilenceAndFullScaleBoundariesRemainFinite() throws {
        for value in [Float(0), 1, -1] {
            let source = [Float](repeating: value, count: 48_000)
            let result = try convert(
                source,
                channels: 1,
                sourceRate: 48_000,
                destinationRate: 96_000
            )

            XCTAssertTrue(result.left.allSatisfy(\.isFinite))
            XCTAssertTrue(result.right.allSatisfy(\.isFinite))
        }
    }

    func testVariablePacketFormatIsRejectedBeforeConversion() {
        var source = format(sampleRate: 48_000, channels: 2)
        source.framesPerPacket = 0
        let destination = format(
            sampleRate: 48_000,
            channels: 2,
            nonInterleaved: true
        )

        XCTAssertNil(TBAudioSampleRateConverterCreate(source, destination, 512, 512))
    }

    func testFrameCapacityBeyondViewByteSizeIsRejected() {
        let source = format(sampleRate: 48_000, channels: 2)
        let destination = format(
            sampleRate: 44_100,
            channels: 2,
            nonInterleaved: true
        )
        let firstUnrepresentableFrameCount = UInt32.max / source.bytesPerFrame + 1

        XCTAssertNil(
            TBAudioSampleRateConverterCreate(
                source,
                destination,
                firstUnrepresentableFrameCount,
                512
            )
        )
    }

    private struct ConversionResult {
        let left: [Float]
        let right: [Float]
        let isBypass: Bool
    }

    private struct ToneMetrics {
        let snrDB: Double
        let thdNDB: Double
        let levelDB: Double
    }

    private enum ConversionError: Error {
        case creationFailed
        case conversionFailed
    }

    private func convert(
        _ interleavedSamples: [Float],
        channels: UInt32,
        sourceRate: Double,
        destinationRate: Double
    ) throws -> ConversionResult {
        let inputFrames = interleavedSamples.count / Int(channels)
        let outputCapacity = Int(ceil(Double(inputFrames) * destinationRate / sourceRate)) + 32
        let sourceFormat = format(sampleRate: sourceRate, channels: channels)
        let destinationFormat = format(
            sampleRate: destinationRate,
            channels: 2,
            nonInterleaved: true
        )
        guard
            let converter = TBAudioSampleRateConverterCreate(
                sourceFormat,
                destinationFormat,
                UInt32(inputFrames),
                UInt32(outputCapacity)
            )
        else {
            throw ConversionError.creationFailed
        }
        defer { TBAudioSampleRateConverterDestroy(converter) }

        var left = [Float](repeating: 0, count: outputCapacity)
        var right = [Float](repeating: 0, count: outputCapacity)
        var producedFrames = 0
        let succeeded = interleavedSamples.withUnsafeBytes { inputBytes in
            left.withUnsafeMutableBytes { leftBytes in
                right.withUnsafeMutableBytes { rightBytes in
                    var input = TBAudioRealtimeInputView(
                        buffers: (inputBytes.baseAddress, nil, nil, nil, nil, nil, nil, nil),
                        byteSizes: (UInt32(inputBytes.count), 0, 0, 0, 0, 0, 0, 0),
                        bufferCount: 1,
                        frameCount: UInt32(inputFrames)
                    )
                    var output = TBAudioRealtimeOutputView(
                        buffers: (
                            leftBytes.baseAddress,
                            rightBytes.baseAddress,
                            nil, nil, nil, nil, nil, nil
                        ),
                        byteSizes: (
                            UInt32(leftBytes.count),
                            UInt32(rightBytes.count),
                            0, 0, 0, 0, 0, 0
                        ),
                        bufferCount: 2,
                        frameCount: UInt32(outputCapacity)
                    )
                    let converted = TBAudioSampleRateConverterConvert(
                        converter,
                        &input,
                        &output
                    )
                    if converted {
                        producedFrames = Int(output.frameCount)
                    }
                    return converted
                }
            }
        }
        guard succeeded else { throw ConversionError.conversionFailed }
        left.removeSubrange(producedFrames..<left.count)
        right.removeSubrange(producedFrames..<right.count)
        return ConversionResult(
            left: left,
            right: right,
            isBypass: TBAudioSampleRateConverterIsBypass(converter)
        )
    }

    private func format(
        sampleRate: Double,
        channels: UInt32,
        nonInterleaved: Bool = false
    ) -> TBAudioRealtimeFormat {
        let bytesPerFrame = nonInterleaved ? UInt32(4) : channels * 4
        var flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        if nonInterleaved {
            flags |= kAudioFormatFlagIsNonInterleaved
        }
        return TBAudioRealtimeFormat(
            sampleRate: sampleRate,
            formatID: kAudioFormatLinearPCM,
            formatFlags: flags,
            bytesPerPacket: bytesPerFrame,
            framesPerPacket: 1,
            bytesPerFrame: bytesPerFrame,
            channelsPerFrame: channels,
            bitsPerChannel: 32
        )
    }

    private func convertChunks(
        _ source: [Float],
        chunkFrames: Int,
        sourceRate: Double,
        destinationRate: Double
    ) throws -> [Float] {
        let outputCapacity = Int(ceil(Double(chunkFrames) * destinationRate / sourceRate)) + 4
        guard
            let converter = TBAudioSampleRateConverterCreate(
                format(sampleRate: sourceRate, channels: 1),
                format(sampleRate: destinationRate, channels: 2, nonInterleaved: true),
                UInt32(chunkFrames),
                UInt32(outputCapacity)
            )
        else {
            throw ConversionError.creationFailed
        }
        defer { TBAudioSampleRateConverterDestroy(converter) }

        var result: [Float] = []
        result.reserveCapacity(Int(Double(source.count) * destinationRate / sourceRate) + 2)
        var offset = 0
        while offset < source.count {
            let frameCount = min(chunkFrames, source.count - offset)
            var left = [Float](repeating: 0, count: outputCapacity)
            var right = [Float](repeating: 0, count: outputCapacity)
            var producedFrames = 0
            let converted = source[offset..<(offset + frameCount)].withUnsafeBytes { inputBytes in
                left.withUnsafeMutableBytes { leftBytes in
                    right.withUnsafeMutableBytes { rightBytes in
                        var input = TBAudioRealtimeInputView(
                            buffers: (
                                inputBytes.baseAddress, nil, nil, nil, nil, nil, nil, nil
                            ),
                            byteSizes: (
                                UInt32(inputBytes.count), 0, 0, 0, 0, 0, 0, 0
                            ),
                            bufferCount: 1,
                            frameCount: UInt32(frameCount)
                        )
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
                            frameCount: UInt32(outputCapacity)
                        )
                        let succeeded = TBAudioSampleRateConverterConvert(
                            converter, &input, &output
                        )
                        producedFrames = Int(output.frameCount)
                        return succeeded
                    }
                }
            }
            guard converted else { throw ConversionError.conversionFailed }
            result.append(contentsOf: left.prefix(producedFrames))
            offset += frameCount
        }
        return result
    }

    private func sine(
        frequency: Double,
        sampleRate: Double,
        duration: Double
    ) -> [Float] {
        (0..<Int(sampleRate * duration)).map { frame in
            Float(0.5 * sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
        }
    }

    private func stableSamples(_ samples: [Float]) -> ArraySlice<Float> {
        let trim = min(4_096, samples.count / 10)
        return samples[trim..<(samples.count - trim)]
    }

    private func toneMetrics(
        samples: [Float],
        frequency: Double,
        sampleRate: Double
    ) -> ToneMetrics {
        let windowFrames = min(Int(sampleRate), samples.count - 8_192)
        let windowStart = (samples.count - windowFrames) / 2
        let stable = samples[windowStart..<(windowStart + windowFrames)]
        var sinProjection = 0.0
        var cosProjection = 0.0
        for (offset, sample) in stable.enumerated() {
            let frame = stable.startIndex + offset
            let phase = 2 * Double.pi * frequency * Double(frame) / sampleRate
            sinProjection += Double(sample) * sin(phase)
            cosProjection += Double(sample) * cos(phase)
        }
        let scale = 2 / Double(stable.count)
        let sinCoefficient = sinProjection * scale
        let cosCoefficient = cosProjection * scale
        let amplitude = hypot(sinCoefficient, cosCoefficient)
        var residualEnergy = 0.0
        for (offset, sample) in stable.enumerated() {
            let frame = stable.startIndex + offset
            let phase = 2 * Double.pi * frequency * Double(frame) / sampleRate
            let fitted = sinCoefficient * sin(phase) + cosCoefficient * cos(phase)
            let residual = Double(sample) - fitted
            residualEnergy += residual * residual
        }
        let noiseRMS = sqrt(residualEnergy / Double(stable.count))
        let signalRMS = amplitude / sqrt(2)
        let snr = 20 * log10(signalRMS / max(noiseRMS, Double.leastNonzeroMagnitude))
        return ToneMetrics(
            snrDB: snr,
            thdNDB: -snr,
            levelDB: 20 * log10(amplitude / 0.5)
        )
    }
}
