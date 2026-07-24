#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void TBAudioApplyGain(float* destination, const float* source, uint32_t sampleCount, float gain);
uint32_t TBAudioMixGain(float* destination, const float* source, uint32_t sampleCount, float gain);
uint32_t TBAudioClamp(float* samples, uint32_t sampleCount);

#ifdef __cplusplus
}
#endif
