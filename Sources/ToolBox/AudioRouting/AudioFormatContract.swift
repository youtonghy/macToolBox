import AudioToolbox
import Foundation

enum AudioFormatContractError: Error, Equatable, Sendable {
    case unsupportedSource
    case unsupportedOutput
    case channelMatrixRequired
}

enum AudioChannelMap: Equatable, Sendable {
    case duplicateMono
    case stereo
    case interleavedStereo
    case nonInterleavedStereo
}

struct CanonicalAudioFormat: Equatable, Sendable {
    let sampleRate: Double
    let channelCount: UInt32 = 2
    let isNonInterleaved = true

    var streamDescription: AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}

struct AudioFormatContract: Equatable, Sendable {
    let source: AudioFormatFingerprint
    let canonical: CanonicalAudioFormat
    let output: AudioFormatFingerprint
    let sourceChannelMap: AudioChannelMap
    let outputChannelMap: AudioChannelMap
    let requiresSampleRateConversion: Bool

    static func negotiate(
        source: AudioStreamBasicDescription,
        output: AudioStreamBasicDescription
    ) throws -> AudioFormatContract {
        let sourceLayout = try validate(source, role: .source)
        let outputLayout = try validate(output, role: .output)
        let ratio = output.mSampleRate / source.mSampleRate
        guard ratio >= 0.125, ratio <= 8 else {
            throw AudioFormatContractError.unsupportedSource
        }

        return AudioFormatContract(
            source: AudioFormatFingerprint(source),
            canonical: CanonicalAudioFormat(sampleRate: output.mSampleRate),
            output: AudioFormatFingerprint(output),
            sourceChannelMap: sourceLayout.channelCount == 1 ? .duplicateMono : .stereo,
            outputChannelMap: outputLayout.isNonInterleaved
                ? .nonInterleavedStereo
                : .interleavedStereo,
            requiresSampleRateConversion: source.mSampleRate != output.mSampleRate
        )
    }

    private enum FormatRole {
        case source
        case output
    }

    private struct Layout {
        let channelCount: UInt32
        let isNonInterleaved: Bool
    }

    private static func validate(
        _ format: AudioStreamBasicDescription,
        role: FormatRole
    ) throws -> Layout {
        guard format.mChannelsPerFrame <= 2 else {
            throw AudioFormatContractError.channelMatrixRequired
        }
        if case .output = role, format.mChannelsPerFrame != 2 {
            throw AudioFormatContractError.unsupportedOutput
        }

        let requiredFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        let prohibitedFlags =
            kAudioFormatFlagIsBigEndian
            | kAudioFormatFlagIsSignedInteger
            | kAudioFormatFlagIsAlignedHigh
        let isNonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let expectedBytesPerFrame =
            isNonInterleaved
            ? UInt32(MemoryLayout<Float>.size)
            : format.mChannelsPerFrame * UInt32(MemoryLayout<Float>.size)
        let isSupported =
            format.mSampleRate.isFinite
            && format.mSampleRate >= 8_000
            && format.mSampleRate <= 384_000
            && format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & requiredFlags == requiredFlags
            && format.mFormatFlags & prohibitedFlags == 0
            && format.mFramesPerPacket == 1
            && format.mBytesPerFrame == expectedBytesPerFrame
            && format.mBytesPerPacket == expectedBytesPerFrame
            && (format.mChannelsPerFrame == 1 || format.mChannelsPerFrame == 2)
            && format.mBitsPerChannel == 32

        guard isSupported else {
            switch role {
            case .source:
                throw AudioFormatContractError.unsupportedSource
            case .output:
                throw AudioFormatContractError.unsupportedOutput
            }
        }

        return Layout(
            channelCount: format.mChannelsPerFrame,
            isNonInterleaved: isNonInterleaved
        )
    }
}

extension AudioFormatFingerprint {
    var streamDescription: AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: formatID,
            mFormatFlags: formatFlags,
            mBytesPerPacket: bytesPerPacket,
            mFramesPerPacket: framesPerPacket,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channelsPerFrame,
            mBitsPerChannel: bitsPerChannel,
            mReserved: 0
        )
    }
}
