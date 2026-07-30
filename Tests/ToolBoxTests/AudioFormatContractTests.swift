import AudioToolbox
import XCTest

@testable import ToolBox

final class AudioFormatContractTests: XCTestCase {
    func testSupportedFormatMatrixUsesOutputRateAndStereoCanonicalLayout() throws {
        for source in [
            fixture(sampleRate: 44_100, channels: 1),
            fixture(sampleRate: 44_100, channels: 2),
            fixture(sampleRate: 48_000, channels: 2, nonInterleaved: true),
            fixture(sampleRate: 96_000, channels: 2),
        ] {
            let contract = try AudioFormatContract.negotiate(
                source: source,
                output: fixture(sampleRate: 48_000, channels: 2, nonInterleaved: true)
            )

            XCTAssertEqual(contract.canonical.channelCount, 2)
            XCTAssertEqual(contract.canonical.sampleRate, 48_000)
            XCTAssertTrue(contract.canonical.isNonInterleaved)
        }
    }

    func testMonoSourceIsDuplicatedToStereo() throws {
        let contract = try AudioFormatContract.negotiate(
            source: fixture(sampleRate: 48_000, channels: 1),
            output: fixture(sampleRate: 48_000, channels: 2)
        )

        XCTAssertEqual(contract.sourceChannelMap, .duplicateMono)
        XCTAssertEqual(contract.outputChannelMap, .interleavedStereo)
        XCTAssertFalse(contract.requiresSampleRateConversion)
    }

    func testNonInterleavedStereoOutputIsRecordedInContract() throws {
        let contract = try AudioFormatContract.negotiate(
            source: fixture(sampleRate: 44_100, channels: 2),
            output: fixture(sampleRate: 48_000, channels: 2, nonInterleaved: true)
        )

        XCTAssertEqual(contract.sourceChannelMap, .stereo)
        XCTAssertEqual(contract.outputChannelMap, .nonInterleavedStereo)
        XCTAssertTrue(contract.requiresSampleRateConversion)
    }

    func testVariablePacketFormatFailsClosed() {
        var source = fixture(sampleRate: 44_100, channels: 2)
        source.mFramesPerPacket = 0

        XCTAssertThrowsError(
            try AudioFormatContract.negotiate(
                source: source,
                output: fixture(sampleRate: 48_000, channels: 2)
            )
        ) { error in
            XCTAssertEqual(error as? AudioFormatContractError, .unsupportedSource)
        }
    }

    func testUnknownSampleTypeFailsClosed() {
        var source = fixture(sampleRate: 48_000, channels: 2)
        source.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked

        XCTAssertThrowsError(
            try AudioFormatContract.negotiate(
                source: source,
                output: fixture(sampleRate: 48_000, channels: 2)
            )
        ) { error in
            XCTAssertEqual(error as? AudioFormatContractError, .unsupportedSource)
        }
    }

    func testMultichannelWithoutExplicitMatrixFailsClosed() {
        XCTAssertThrowsError(
            try AudioFormatContract.negotiate(
                source: fixture(sampleRate: 48_000, channels: 6),
                output: fixture(sampleRate: 48_000, channels: 2)
            )
        ) { error in
            XCTAssertEqual(error as? AudioFormatContractError, .channelMatrixRequired)
        }
    }

    func testMalformedOutputFailsClosedIndependently() {
        var output = fixture(sampleRate: 48_000, channels: 2)
        output.mBytesPerFrame = 4

        XCTAssertThrowsError(
            try AudioFormatContract.negotiate(
                source: fixture(sampleRate: 48_000, channels: 2),
                output: output
            )
        ) { error in
            XCTAssertEqual(error as? AudioFormatContractError, .unsupportedOutput)
        }
    }

    private func fixture(
        sampleRate: Double,
        channels: UInt32,
        nonInterleaved: Bool = false
    ) -> AudioStreamBasicDescription {
        let bytesPerFrame = nonInterleaved ? UInt32(MemoryLayout<Float>.size) : channels * 4
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
}
