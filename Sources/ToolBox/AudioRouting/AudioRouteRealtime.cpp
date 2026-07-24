#include "AudioRouteRealtime.hpp"

#include <algorithm>
#include <cmath>
#include <new>
#include <stdexcept>

namespace {
constexpr double kMaximumRateCorrection = 0.001;

bool IsPowerOfTwo(uint32_t value) noexcept {
    return value >= 4 && (value & (value - 1)) == 0;
}

uint64_t RequiredInputFrames(
    double readPosition,
    uint32_t outputFrames,
    double rate
) noexcept {
    const uint64_t firstFrame = static_cast<uint64_t>(readPosition);
    const double lastPosition = readPosition + static_cast<double>(outputFrames - 1) * rate;
    const uint64_t lastFrame = static_cast<uint64_t>(lastPosition);
    return lastFrame - firstFrame + 1
        + (lastPosition == static_cast<double>(lastFrame) ? 0 : 1);
}
}

TBAudioStereoRingBuffer::TBAudioStereoRingBuffer(
    uint32_t targetFrames,
    uint32_t capacityFrames,
    uint32_t gainRampFrames
) : samples_(std::make_unique<float[]>(capacityFrames * 2)),
    targetFrames_(std::max<uint32_t>(2, std::min(targetFrames, capacityFrames / 2))),
    highWaterFramesThreshold_(std::min(capacityFrames - 2, targetFrames_ * 2)),
    capacityFrames_(capacityFrames),
    capacityMask_(capacityFrames - 1),
    gainRampFrames_(std::max<uint32_t>(1, gainRampFrames)) {
    if (!IsPowerOfTwo(capacityFrames)) throw std::invalid_argument("capacityFrames must be a power of two");
}

void TBAudioStereoRingBuffer::Write(const float* source, uint32_t frameCount) noexcept {
    if (source == nullptr || frameCount == 0) return;
    const uint64_t read = readFrame_.load(std::memory_order_acquire);
    const uint64_t write = writeFrame_.load(std::memory_order_relaxed);
    const uint32_t available = static_cast<uint32_t>(
        capacityFrames_ - std::min<uint64_t>(write - read, capacityFrames_)
    );
    const uint32_t framesToWrite = std::min(frameCount, available);
    for (uint32_t frame = 0; frame < framesToWrite; ++frame) {
        const uint32_t slot = static_cast<uint32_t>((write + frame) & capacityMask_);
        for (uint32_t channel = 0; channel < 2; ++channel) {
            const float sample = source[frame * 2 + channel];
            if (std::isfinite(sample)) {
                samples_[slot * 2 + channel] = sample;
            } else {
                samples_[slot * 2 + channel] = 0;
                nonFiniteSamples_.fetch_add(1, std::memory_order_relaxed);
            }
        }
    }
    writeFrame_.store(write + framesToWrite, std::memory_order_release);
    droppedFrames_.fetch_add(frameCount - framesToWrite, std::memory_order_relaxed);
    const uint64_t occupancy = std::min<uint64_t>(write + framesToWrite - read, capacityFrames_);
    uint64_t highWater = highWaterFrames_.load(std::memory_order_relaxed);
    while (occupancy > highWater
           && !highWaterFrames_.compare_exchange_weak(highWater, occupancy, std::memory_order_relaxed)) {}
}

void TBAudioStereoRingBuffer::Mix(float* destination, uint32_t frameCount, float targetGain) noexcept {
    if (destination == nullptr || frameCount == 0) return;
    const uint64_t write = writeFrame_.load(std::memory_order_acquire);
    uint64_t read = readFrame_.load(std::memory_order_relaxed);
    uint64_t available = write - read;
    const uint64_t mixTargetFrames = std::min<uint64_t>(
        capacityFrames_, std::max<uint64_t>(targetFrames_, frameCount)
    );
    if (!primed_ && available < mixTargetFrames) {
        warmupFrames_.fetch_add(frameCount, std::memory_order_relaxed);
        return;
    }
    if (!primed_) {
        readPosition_ = static_cast<double>(read);
        primed_ = true;
    }
    const uint64_t twoCallbackFrames = std::min<uint64_t>(
        capacityFrames_, static_cast<uint64_t>(frameCount) * 2
    );
    const uint64_t highWaterThreshold = std::min<uint64_t>(
        capacityFrames_, std::max<uint64_t>(highWaterFramesThreshold_, twoCallbackFrames)
    );
    // The configured target already buffers normal small callbacks. Large callbacks
    // retain two periods so trimming stale audio cannot cause the next underrun.
    const uint64_t resyncRetainedFrames = std::max<uint64_t>(
        targetFrames_, twoCallbackFrames
    );
    if (available > highWaterThreshold) {
        read = write - resyncRetainedFrames;
        readPosition_ = static_cast<double>(read);
        readFrame_.store(read, std::memory_order_release);
        available = resyncRetainedFrames;
        recoveryGain_ = 0;
        forcedResyncCount_.fetch_add(1, std::memory_order_relaxed);
    }

    const double occupancyError = (
        static_cast<double>(available) - mixTargetFrames
    ) / mixTargetFrames;
    const double correction = std::min(
        std::max(occupancyError * 0.0001, -kMaximumRateCorrection), kMaximumRateCorrection
    );
    double rate = 1.0 + correction;
    uint64_t required = RequiredInputFrames(readPosition_, frameCount, rate);
    const bool preservesTargetReserve = available >= required
        && available - required >= mixTargetFrames;
    if (correction > 0 && !preservesTargetReserve) {
        // Do not let drift correction turn a playable callback into a future-frame read.
        rate = 1.0;
        required = RequiredInputFrames(readPosition_, frameCount, rate);
    }
    if (available < required) {
        primed_ = false;
        recoveryGain_ = 0;
        readPosition_ = static_cast<double>(write);
        readFrame_.store(write, std::memory_order_release);
        underrunFrames_.fetch_add(frameCount, std::memory_order_relaxed);
        return;
    }

    const float boundedTargetGain = std::isfinite(targetGain)
        ? std::min(std::max(targetGain, 0.0f), 3.0f)
        : 0.0f;
    if (boundedTargetGain != targetGain_) {
        targetGain_ = boundedTargetGain;
        gainStep_ = (targetGain_ - currentGain_) / gainRampFrames_;
        gainRampFramesRemaining_ = gainRampFrames_;
    }
    for (uint32_t frame = 0; frame < frameCount; ++frame) {
        if (gainRampFramesRemaining_ > 0) {
            currentGain_ += gainStep_;
            gainRampFramesRemaining_ -= 1;
            if (gainRampFramesRemaining_ == 0) currentGain_ = targetGain_;
        }
        recoveryGain_ = std::min(1.0f, recoveryGain_ + 1.0f / gainRampFrames_);

        const uint64_t baseFrame = static_cast<uint64_t>(readPosition_);
        const float fraction = static_cast<float>(readPosition_ - baseFrame);
        const uint32_t first = static_cast<uint32_t>(baseFrame & capacityMask_);
        const uint32_t second = static_cast<uint32_t>((baseFrame + 1) & capacityMask_);
        for (uint32_t channel = 0; channel < 2; ++channel) {
            const float firstSample = samples_[first * 2 + channel];
            const float sample = fraction == 0
                ? firstSample
                : firstSample + (samples_[second * 2 + channel] - firstSample) * fraction;
            destination[frame * 2 + channel] += sample * currentGain_ * recoveryGain_;
        }
        readPosition_ += rate;
    }
    readFrame_.store(static_cast<uint64_t>(readPosition_), std::memory_order_release);
}

uint64_t TBAudioStereoRingBuffer::OccupancyFrames() const noexcept {
    const uint64_t read = readFrame_.load(std::memory_order_acquire);
    const uint64_t write = writeFrame_.load(std::memory_order_acquire);
    return std::min<uint64_t>(write - read, capacityFrames_);
}

uint64_t TBAudioStereoRingBuffer::HighWaterFrames() const noexcept { return highWaterFrames_.load(); }
uint64_t TBAudioStereoRingBuffer::WarmupFrames() const noexcept { return warmupFrames_.load(); }
uint64_t TBAudioStereoRingBuffer::UnderrunFrames() const noexcept { return underrunFrames_.load(); }
uint64_t TBAudioStereoRingBuffer::DroppedFrames() const noexcept { return droppedFrames_.load(); }
uint64_t TBAudioStereoRingBuffer::ForcedResyncCount() const noexcept { return forcedResyncCount_.load(); }
uint64_t TBAudioStereoRingBuffer::NonFiniteSamples() const noexcept { return nonFiniteSamples_.load(); }

uint32_t TBAudioRecommendedTargetFrames(
    uint32_t bufferFrames,
    uint32_t latencyFrames,
    uint32_t safetyOffsetFrames
) {
    const uint64_t proposed = static_cast<uint64_t>(bufferFrames) * 2
        + latencyFrames + safetyOffsetFrames;
    return static_cast<uint32_t>(std::min<uint64_t>(2048, std::max<uint64_t>(256, proposed)));
}

struct TBAudioRealtimeTestState {
    TBAudioStereoRingBuffer ring;
    TBAudioRealtimeTestState(uint32_t target, uint32_t capacity, uint32_t ramp)
        : ring(target, capacity, ramp) {}
};

TBAudioRealtimeTestState* TBAudioRealtimeTestCreate(
    uint32_t targetFrames,
    uint32_t capacityFrames,
    uint32_t gainRampFrames
) {
    try {
        return new TBAudioRealtimeTestState(targetFrames, capacityFrames, gainRampFrames);
    } catch (...) {
        return nullptr;
    }
}

void TBAudioRealtimeTestDestroy(TBAudioRealtimeTestState* state) { delete state; }
void TBAudioRealtimeTestWrite(TBAudioRealtimeTestState* state, const float* source, uint32_t frameCount) {
    if (state != nullptr) state->ring.Write(source, frameCount);
}
void TBAudioRealtimeTestMix(
    TBAudioRealtimeTestState* state,
    float* destination,
    uint32_t frameCount,
    float targetGain
) {
    if (state != nullptr) state->ring.Mix(destination, frameCount, targetGain);
}
uint64_t TBAudioRealtimeTestForcedResyncCount(const TBAudioRealtimeTestState* state) {
    return state == nullptr ? 0 : state->ring.ForcedResyncCount();
}
uint64_t TBAudioRealtimeTestOccupancyFrames(const TBAudioRealtimeTestState* state) {
    return state == nullptr ? 0 : state->ring.OccupancyFrames();
}
uint64_t TBAudioRealtimeTestHighWaterFrames(const TBAudioRealtimeTestState* state) {
    return state == nullptr ? 0 : state->ring.HighWaterFrames();
}
uint64_t TBAudioRealtimeTestUnderrunFrames(const TBAudioRealtimeTestState* state) {
    return state == nullptr ? 0 : state->ring.UnderrunFrames();
}
uint64_t TBAudioRealtimeTestDroppedFrames(const TBAudioRealtimeTestState* state) {
    return state == nullptr ? 0 : state->ring.DroppedFrames();
}
uint64_t TBAudioRealtimeTestNonFiniteSamples(const TBAudioRealtimeTestState* state) {
    return state == nullptr ? 0 : state->ring.NonFiniteSamples();
}
