#include "AudioRouteDSP.hpp"

#include <cmath>

void TBAudioApplyGain(float* destination, const float* source, uint32_t sampleCount, float gain) {
    if (destination == nullptr || source == nullptr) return;
    for (uint32_t index = 0; index < sampleCount; ++index) {
        destination[index] = source[index] * gain;
    }
}

uint32_t TBAudioMixGain(float* destination, const float* source, uint32_t sampleCount, float gain) {
    if (destination == nullptr || source == nullptr) return 0;
    uint32_t clipped = 0;
    for (uint32_t index = 0; index < sampleCount; ++index) {
        const float mixed = destination[index] + source[index] * gain;
        destination[index] = mixed;
        clipped += std::fabs(mixed) > 1.0f;
    }
    return clipped;
}

uint32_t TBAudioClamp(float* samples, uint32_t sampleCount) {
    if (samples == nullptr) return 0;
    uint32_t clipped = 0;
    for (uint32_t index = 0; index < sampleCount; ++index) {
        const float sample = samples[index];
        if (!std::isfinite(sample)) {
            samples[index] = 0;
            ++clipped;
        } else if (sample > 1.0f) {
            samples[index] = 1.0f;
            ++clipped;
        } else if (sample < -1.0f) {
            samples[index] = -1.0f;
            ++clipped;
        }
    }
    return clipped;
}
