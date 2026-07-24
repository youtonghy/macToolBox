#include "AudioRouteFormat.hpp"

#include <AudioToolbox/AudioFormat.h>
#include <algorithm>
#include <cmath>

namespace {
constexpr double kMaximumRateCorrection = 0.001;
}

uint32_t TBAudioOutputFormatCompatibility(
    const AudioStreamBasicDescription* formats,
    uint32_t formatCount
) {
    if (formats == nullptr || formatCount == 0) return TBAudioOutputFormatMissingStream;
    if (formatCount != 1) return TBAudioOutputFormatMultipleStreams;

    const AudioStreamBasicDescription& format = formats[0];
    if (!std::isfinite(format.mSampleRate) || format.mSampleRate <= 0) {
        return TBAudioOutputFormatInvalidSampleRate;
    }
    if (format.mFormatID != kAudioFormatLinearPCM) return TBAudioOutputFormatNonLinearPCM;
    if ((format.mFormatFlags & kAudioFormatFlagIsFloat) == 0 || format.mBitsPerChannel != 32) {
        return TBAudioOutputFormatRequiresFloat32;
    }
    if ((format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        || format.mChannelsPerFrame != 2) {
        return TBAudioOutputFormatRequiresInterleavedStereo;
    }
    if ((format.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0) {
        return TBAudioOutputFormatRequiresNativeEndian;
    }
    if ((format.mFormatFlags & kAudioFormatFlagIsPacked) == 0
        || format.mFramesPerPacket != 1
        || format.mBytesPerFrame != 2 * sizeof(float)
        || format.mBytesPerPacket != format.mBytesPerFrame) {
        return TBAudioOutputFormatRequiresPackedFrames;
    }
    return TBAudioOutputFormatSupported;
}

bool TBAudioSampleRatesCompatible(double captureSampleRate, double outputSampleRate) {
    if (!std::isfinite(captureSampleRate) || !std::isfinite(outputSampleRate)
        || captureSampleRate <= 0 || outputSampleRate <= 0) {
        return false;
    }
    const double scale = std::max(captureSampleRate, outputSampleRate);
    return std::fabs(captureSampleRate - outputSampleRate) / scale <= kMaximumRateCorrection;
}
