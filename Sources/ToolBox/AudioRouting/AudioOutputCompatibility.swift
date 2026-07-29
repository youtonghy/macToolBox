import CoreAudio
import Foundation

enum AudioOutputCompatibilityIssue: Int, Codable, Equatable, Sendable {
    case missingOutputStream = 1
    case multipleOutputStreams = 2
    case invalidSampleRate = 3
    case requiresLinearPCM = 4
    case requiresFloat32 = 5
    case requiresInterleavedStereo = 6
    case requiresNativeEndian = 7
    case requiresPackedFrames = 8
    case formatQueryFailed = 9
    case sampleRateMismatch = 10
    case unknownNativeResult = 11
    case bluetoothProfileChanging = 12

    var message: String {
        switch self {
        case .missingOutputStream: "设备没有可用输出流"
        case .multipleOutputStreams: "暂不支持多输出流设备"
        case .invalidSampleRate: "设备采样率无效"
        case .requiresLinearPCM: "暂只支持 Linear PCM 输出"
        case .requiresFloat32: "暂只支持 Float32 输出"
        case .requiresInterleavedStereo: "暂只支持交错双声道输出"
        case .requiresNativeEndian: "暂不支持大端序音频输出"
        case .requiresPackedFrames: "暂只支持 packed 单帧 PCM 输出"
        case .formatQueryFailed: "无法读取设备输出格式"
        case .sampleRateMismatch: "设备采样率与当前系统输出不一致，暂不支持跨采样率转换"
        case .unknownNativeResult: "设备兼容性检查返回了未知错误"
        case .bluetoothProfileChanging: "蓝牙耳机正在切换通话音频模式，已暂停路由"
        }
    }
}

struct HALAudioStreamFormatRecord: Equatable, Sendable {
    let sampleRate: Double
    let formatID: AudioFormatID
    let formatFlags: AudioFormatFlags
    let bytesPerPacket: UInt32
    let framesPerPacket: UInt32
    let bytesPerFrame: UInt32
    let channelsPerFrame: UInt32
    let bitsPerChannel: UInt32

    init(_ format: AudioStreamBasicDescription) {
        self.init(
            sampleRate: format.mSampleRate,
            formatID: format.mFormatID,
            formatFlags: format.mFormatFlags,
            bytesPerPacket: format.mBytesPerPacket,
            framesPerPacket: format.mFramesPerPacket,
            bytesPerFrame: format.mBytesPerFrame,
            channelsPerFrame: format.mChannelsPerFrame,
            bitsPerChannel: format.mBitsPerChannel
        )
    }

    init(
        sampleRate: Double,
        formatID: AudioFormatID,
        formatFlags: AudioFormatFlags,
        bytesPerPacket: UInt32,
        framesPerPacket: UInt32,
        bytesPerFrame: UInt32,
        channelsPerFrame: UInt32,
        bitsPerChannel: UInt32
    ) {
        self.sampleRate = sampleRate
        self.formatID = formatID
        self.formatFlags = formatFlags
        self.bytesPerPacket = bytesPerPacket
        self.framesPerPacket = framesPerPacket
        self.bytesPerFrame = bytesPerFrame
        self.channelsPerFrame = channelsPerFrame
        self.bitsPerChannel = bitsPerChannel
    }

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

enum AudioOutputCompatibility {
    static func issue(forNativeCode code: UInt32) -> AudioOutputCompatibilityIssue? {
        guard code != TBAudioOutputFormatSupported else { return nil }
        return AudioOutputCompatibilityIssue(rawValue: Int(code)) ?? .unknownNativeResult
    }

    static func evaluate(
        streamFormats: [HALAudioStreamFormatRecord],
        captureSampleRate: Double? = nil
    ) -> AudioOutputCompatibilityIssue? {
        let descriptions = streamFormats.map(\.streamDescription)
        let code = descriptions.withUnsafeBufferPointer { buffer in
            TBAudioOutputFormatCompatibility(buffer.baseAddress, UInt32(buffer.count))
        }
        if let issue = issue(forNativeCode: code) { return issue }
        if let captureSampleRate,
           !TBAudioSampleRatesCompatible(captureSampleRate, descriptions[0].mSampleRate) {
            return .sampleRateMismatch
        }
        return nil
    }
}
