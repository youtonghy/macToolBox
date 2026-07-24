import CoreAudio
import XCTest
@testable import ToolBox

final class AudioOutputCompatibilityTests: XCTestCase {
    func testUnknownNativeCompatibilityCodeRemainsDistinct() {
        XCTAssertEqual(
            AudioOutputCompatibility.issue(forNativeCode: 999),
            .unknownNativeResult
        )
    }

    func testInterleavedStereoFloat32StreamIsSupported() {
        XCTAssertNil(AudioOutputCompatibility.evaluate(streamFormats: [.supportedStereo()]))
    }

    func testCompatibilityRejectsFormatsOutsideNativeEngineBoundary() {
        XCTAssertEqual(AudioOutputCompatibility.evaluate(streamFormats: []), .missingOutputStream)
        XCTAssertEqual(
            AudioOutputCompatibility.evaluate(streamFormats: [.supportedStereo(), .supportedStereo()]),
            .multipleOutputStreams
        )
        XCTAssertEqual(
            AudioOutputCompatibility.evaluate(streamFormats: [.supportedStereo(channels: 1)]),
            .requiresInterleavedStereo
        )
        XCTAssertEqual(
            AudioOutputCompatibility.evaluate(
                streamFormats: [.supportedStereo(flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved)]
            ),
            .requiresInterleavedStereo
        )
        XCTAssertEqual(
            AudioOutputCompatibility.evaluate(streamFormats: [.supportedStereo(sampleRate: 0)]),
            .invalidSampleRate
        )
    }

    func testCompatibilityRejectsSampleRatesOutsideDriftCorrectionRange() {
        XCTAssertEqual(
            AudioOutputCompatibility.evaluate(
                streamFormats: [.supportedStereo(sampleRate: 44_100)],
                captureSampleRate: 48_000
            ),
            .sampleRateMismatch
        )
        XCTAssertNil(
            AudioOutputCompatibility.evaluate(
                streamFormats: [.supportedStereo(sampleRate: 48_024)],
                captureSampleRate: 48_000
            )
        )
    }

    func testDeviceProjectionPreservesCompatibilityIssue() {
        let records = [
            HALAudioDeviceRecord(
                uid: "hdmi",
                name: "Display",
                hasOutput: true,
                compatibilityIssue: .multipleOutputStreams
            )
        ]

        let device = AudioDeviceRegistry.project(records: records, rememberedUIDs: []).first

        XCTAssertEqual(device?.compatibilityIssue, .multipleOutputStreams)
        XCTAssertEqual(device?.isRoutable, false)
    }

    func testDeviceProjectionRejectsRateMismatchBeforeNativeStart() {
        let records = [
            HALAudioDeviceRecord(
                uid: "speakers",
                name: "Speakers",
                hasOutput: true,
                sampleRate: 48_000
            ),
            HALAudioDeviceRecord(
                uid: "headset",
                name: "Headset",
                hasOutput: true,
                sampleRate: 44_100
            )
        ]

        let devices = AudioDeviceRegistry.project(
            records: records,
            rememberedUIDs: [],
            captureSampleRate: 48_000
        )

        XCTAssertNil(devices.first(where: { $0.uid == "speakers" })?.compatibilityIssue)
        XCTAssertEqual(
            devices.first(where: { $0.uid == "headset" })?.compatibilityIssue,
            .sampleRateMismatch
        )
    }
}

private extension HALAudioStreamFormatRecord {
    static func supportedStereo(
        sampleRate: Double = 48_000,
        flags: AudioFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        channels: UInt32 = 2
    ) -> Self {
        Self(
            sampleRate: sampleRate,
            formatID: kAudioFormatLinearPCM,
            formatFlags: flags,
            bytesPerPacket: channels * 4,
            framesPerPacket: 1,
            bytesPerFrame: channels * 4,
            channelsPerFrame: channels,
            bitsPerChannel: 32
        )
    }
}
