import CoreAudio
@testable import ToolBox

enum AudioRouteTestFixtures {
    static func format(sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
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
        outputSampleRate: Double = 48_000,
        processDeviceID: AudioObjectID = 100
    ) -> HALObservationSnapshot {
        HALObservationSnapshot(
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
                        42: AudioFormatFingerprint(format(sampleRate: tapSampleRate))
                    ]
                )
            ]
        )
    }
}
