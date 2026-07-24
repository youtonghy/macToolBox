#pragma once

#include <CoreAudio/CoreAudioTypes.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    TBAudioOutputFormatSupported = 0,
    TBAudioOutputFormatMissingStream = 1,
    TBAudioOutputFormatMultipleStreams = 2,
    TBAudioOutputFormatInvalidSampleRate = 3,
    TBAudioOutputFormatNonLinearPCM = 4,
    TBAudioOutputFormatRequiresFloat32 = 5,
    TBAudioOutputFormatRequiresInterleavedStereo = 6,
    TBAudioOutputFormatRequiresNativeEndian = 7,
    TBAudioOutputFormatRequiresPackedFrames = 8
};

uint32_t TBAudioOutputFormatCompatibility(
    const AudioStreamBasicDescription* formats,
    uint32_t formatCount
);
bool TBAudioSampleRatesCompatible(double captureSampleRate, double outputSampleRate);

#ifdef __cplusplus
}
#endif
