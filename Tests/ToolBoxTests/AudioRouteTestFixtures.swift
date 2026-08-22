import CoreAudio
@testable import ToolBoxCore

enum AudioRouteTestFixtures {
    static func healthSample(
        captureFrameCount: UInt64 = 0,
        outputFrameCount: UInt64 = 0,
        sourceFatalCount: UInt64 = 0,
        underrunFrameCount: UInt64 = 0,
        overrunFrameCount: UInt64 = 0,
        forcedResyncCount: UInt64 = 0,
        formatMismatchCount: UInt64 = 0,
        nonFiniteSampleCount: UInt64 = 0,
        clippedSampleCount: UInt64 = 0,
        outputPeriodFrames: UInt64 = 256,
        sourceIsProducingOutput: Bool = true
    ) -> AudioRouteHealthSample {
        AudioRouteHealthSample(
            captureFrameCount: captureFrameCount,
            outputFrameCount: outputFrameCount,
            sourceFatalCount: sourceFatalCount,
            underrunFrameCount: underrunFrameCount,
            overrunFrameCount: overrunFrameCount,
            forcedResyncCount: forcedResyncCount,
            formatMismatchCount: formatMismatchCount,
            nonFiniteSampleCount: nonFiniteSampleCount,
            clippedSampleCount: clippedSampleCount,
            outputPeriodFrames: outputPeriodFrames,
            sourceIsProducingOutput: sourceIsProducingOutput
        )
    }

    static func format(
        sampleRate: Double,
        channels: UInt32 = 2,
        nonInterleaved: Bool = false
    ) -> AudioStreamBasicDescription {
        let bytesPerFrame = nonInterleaved
            ? UInt32(MemoryLayout<Float>.size)
            : channels * UInt32(MemoryLayout<Float>.size)
        var flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        if nonInterleaved {
            flags |= kAudioFormatFlagIsNonInterleaved
        }
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    static func intent(
        generation: UInt64 = 1,
        outputUID: String = "output-A",
        gain: Float = 1
    ) -> AudioRuntimeIntent {
        let source = AudioRouteSource(
            bundleID: "com.example.player",
            processObjectID: 42,
            linearGain: gain
        )
        let plan = AudioRoutePlan(outputDeviceUID: outputUID, sources: [source])
        return AudioRuntimeIntent(
            generation: generation,
            plansByID: [plan.id: plan],
            mutedRouteIDs: []
        )
    }

    static func observation(
        server: UInt64 = 1,
        outputUID: String = "output-A",
        tapSampleRate: Double = 48_000,
        aggregateSampleRate: Double? = nil,
        outputSampleRate: Double = 48_000,
        processDeviceID: AudioObjectID = 100
    ) -> HALObservationSnapshot {
        let aggregateSampleRate = aggregateSampleRate ?? tapSampleRate

        return HALObservationSnapshot(
            audioServerGeneration: server,
            routesByID: [
                outputUID: HALRouteObservation(
                    outputDeviceID: 200,
                    outputFormat: AudioFormatFingerprint(
                        format(sampleRate: outputSampleRate)
                    ),
                    processDeviceIDsByObjectID: [42: [processDeviceID]],
                    tapFormatsByProcessObjectID: [
                        42: AudioFormatFingerprint(format(sampleRate: tapSampleRate))
                    ],
                    aggregateFormatsByProcessObjectID: [
                        42: AudioFormatFingerprint(format(sampleRate: aggregateSampleRate))
                    ]
                )
            ]
        )
    }
}
