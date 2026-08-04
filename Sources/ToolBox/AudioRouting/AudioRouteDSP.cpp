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

// Final safety stage before the hardware: bounds samples to [-1, 1] and sanitizes
// non-finite values. Below the knee (|x| <= kLimitThreshold) the signal is passed
// through untouched, so a single source at 100% keeps its original gain.
// Above the knee a smooth, C1-continuous soft-knee limiter takes over instead of
// the previous hard clamp: hard clipping summed/boosted mixes produced dense
// odd-order harmonics heard as sustained "electric"/static crackle. The limiter
// asymptotically approaches +/-1.0 (never exceeds it) so it is still DAC-safe,
// while replacing the harsh cliff with gentle saturation.
//
// Loudness impact at the knee choices below: a full-scale sample (1.0) maps to
// ~0.963 (-0.3 dB, effectively inaudible); a 3x-boosted sample (3.0) maps to
// ~1.0 instead of a hard-clipped square wave. Normal-level audio is uncolored.
uint32_t TBAudioClamp(float* samples, uint32_t sampleCount) {
    if (samples == nullptr) return 0;
    static constexpr float kLimitThreshold = 0.9f;  // unity below; soft-limit above
    static constexpr float kLimitSpan = 1.0f - kLimitThreshold;
    uint32_t clipped = 0;
    for (uint32_t index = 0; index < sampleCount; ++index) {
        const float sample = samples[index];
        if (!std::isfinite(sample)) {
            samples[index] = 0;
            ++clipped;
            continue;
        }
        const float magnitude = std::fabs(sample);
        if (magnitude <= kLimitThreshold) {
            continue;  // unity gain; sample already in place
        }
        const float sign = std::copysignf(1.0f, sample);
        const float t = (magnitude - kLimitThreshold) / kLimitSpan;
        const float limited =
            kLimitThreshold + kLimitSpan * (1.0f - std::exp(-t));
        samples[index] = sign * limited;
        ++clipped;  // reports "limiting engaged" for diagnostics parity
    }
    return clipped;
}
