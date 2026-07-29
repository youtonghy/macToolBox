#pragma once

#include <stdint.h>

#ifdef __cplusplus
#include <atomic>
#include <memory>

class TBAudioStereoRingBuffer {
public:
    TBAudioStereoRingBuffer(uint32_t targetFrames, uint32_t capacityFrames, uint32_t gainRampFrames);

    void Write(const float* source, uint32_t frameCount) noexcept;
    void Mix(float* destination, uint32_t frameCount, float targetGain) noexcept;
    void MixWithRamp(
        float* destination,
        uint32_t frameCount,
        float targetGain,
        uint32_t rampFrames
    ) noexcept;

    uint64_t OccupancyFrames() const noexcept;
    uint64_t HighWaterFrames() const noexcept;
    uint64_t WarmupFrames() const noexcept;
    uint64_t UnderrunFrames() const noexcept;
    uint64_t DroppedFrames() const noexcept;
    uint64_t ForcedResyncCount() const noexcept;
    uint64_t NonFiniteSamples() const noexcept;

private:
    std::unique_ptr<float[]> samples_;
    const uint32_t targetFrames_;
    const uint32_t highWaterFramesThreshold_;
    const uint32_t capacityFrames_;
    const uint32_t capacityMask_;
    const uint32_t gainRampFrames_;
    std::atomic<uint64_t> readFrame_{0};
    std::atomic<uint64_t> writeFrame_{0};
    std::atomic<uint64_t> droppedFrames_{0};
    std::atomic<uint64_t> underrunFrames_{0};
    std::atomic<uint64_t> warmupFrames_{0};
    std::atomic<uint64_t> highWaterFrames_{0};
    std::atomic<uint64_t> forcedResyncCount_{0};
    std::atomic<uint64_t> nonFiniteSamples_{0};
    bool primed_ = false;
    double readPosition_ = 0;
    float currentGain_ = 1;
    float targetGain_ = 1;
    float gainStep_ = 0;
    uint32_t gainRampFramesRemaining_ = 0;
    float recoveryGain_ = 0;
};
#endif

#ifdef __cplusplus
extern "C" {
#endif

uint32_t TBAudioRecommendedTargetFrames(
    uint32_t bufferFrames,
    uint32_t latencyFrames,
    uint32_t safetyOffsetFrames
);

typedef struct TBAudioRealtimeTestState TBAudioRealtimeTestState;
TBAudioRealtimeTestState* TBAudioRealtimeTestCreate(
    uint32_t targetFrames,
    uint32_t capacityFrames,
    uint32_t gainRampFrames
);
void TBAudioRealtimeTestDestroy(TBAudioRealtimeTestState* state);
void TBAudioRealtimeTestWrite(TBAudioRealtimeTestState* state, const float* source, uint32_t frameCount);
void TBAudioRealtimeTestMix(
    TBAudioRealtimeTestState* state,
    float* destination,
    uint32_t frameCount,
    float targetGain
);
uint64_t TBAudioRealtimeTestForcedResyncCount(const TBAudioRealtimeTestState* state);
uint64_t TBAudioRealtimeTestOccupancyFrames(const TBAudioRealtimeTestState* state);
uint64_t TBAudioRealtimeTestHighWaterFrames(const TBAudioRealtimeTestState* state);
uint64_t TBAudioRealtimeTestUnderrunFrames(const TBAudioRealtimeTestState* state);
uint64_t TBAudioRealtimeTestDroppedFrames(const TBAudioRealtimeTestState* state);
uint64_t TBAudioRealtimeTestNonFiniteSamples(const TBAudioRealtimeTestState* state);

#ifdef __cplusplus
}
#endif
