#include "AudioRouteRealtimeKernel.hpp"

#include "AudioRouteDSP.hpp"
#include "AudioRouteFormat.hpp"
#include "AudioRouteRealtime.hpp"

#include <AudioToolbox/AudioFormat.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>
#include <new>
#include <vector>

namespace {
static_assert(
    __atomic_always_lock_free(sizeof(uint32_t), nullptr),
    "The realtime kernel requires lock-free 32-bit atomics"
);
static_assert(
    __atomic_always_lock_free(sizeof(uint64_t), nullptr),
    "The realtime kernel requires lock-free 64-bit atomics"
);

uint32_t FloatBits(float value) noexcept {
    uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

float FloatFromBits(uint32_t bits) noexcept {
    float value = 0;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

bool IsPackedFloat32Stereo(const TBAudioRealtimeFormat& format) noexcept {
    const uint32_t requiredFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    return std::isfinite(format.sampleRate)
        && format.sampleRate > 0
        && format.formatID == kAudioFormatLinearPCM
        && (format.formatFlags & requiredFlags) == requiredFlags
        && (format.formatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        && format.bytesPerFrame == 2 * sizeof(float)
        && format.channelsPerFrame == 2
        && format.bitsPerChannel == 32;
}

void ZeroOutput(TBAudioRealtimeOutputView* output) noexcept {
    if (output == nullptr) return;
    const uint32_t count = std::min<uint32_t>(output->bufferCount, 8);
    for (uint32_t index = 0; index < count; ++index) {
        if (output->buffers[index] != nullptr) {
            std::memset(output->buffers[index], 0, output->byteSizes[index]);
        }
    }
}

bool IsValidInput(const TBAudioRealtimeInputView* input) noexcept {
    if (input == nullptr || input->bufferCount != 1 || input->buffers[0] == nullptr) return false;
    const uint64_t requiredBytes = static_cast<uint64_t>(input->frameCount) * 2 * sizeof(float);
    return input->byteSizes[0] >= requiredBytes;
}

bool IsValidOutput(const TBAudioRealtimeOutputView* output) noexcept {
    if (output == nullptr || output->bufferCount != 1 || output->buffers[0] == nullptr) return false;
    const uint64_t requiredBytes = static_cast<uint64_t>(output->frameCount) * 2 * sizeof(float);
    return output->byteSizes[0] >= requiredBytes;
}

struct SourceState {
    SourceState(uint32_t targetFrames, uint32_t capacityFrames, uint32_t rampFrames)
        : ring(targetFrames, capacityFrames, rampFrames),
          defaultRampFrames(rampFrames),
          gainBits(FloatBits(1)) {}

    TBAudioStereoRingBuffer ring;
    const uint32_t defaultRampFrames;
    std::atomic<uint32_t> gainBits;
    std::atomic<uint32_t> muteRampFrames{0};
    std::atomic<uint32_t> muted{0};
};
}

struct TBAudioRealtimeKernel {
    TBAudioRealtimeKernel(
        uint64_t valueGeneration,
        uint32_t sourceCount,
        uint32_t targetFrames,
        uint32_t capacityFrames,
        uint32_t rampFrames
    ) : generation(valueGeneration) {
        sources.reserve(sourceCount);
        for (uint32_t index = 0; index < sourceCount; ++index) {
            sources.push_back(std::make_unique<SourceState>(
                targetFrames, capacityFrames, rampFrames
            ));
        }
    }

    const uint64_t generation;
    std::vector<std::unique_ptr<SourceState>> sources;
    std::atomic<uint32_t> attached{1};
    std::atomic<uint64_t> captureCallbackCount{0};
    std::atomic<uint64_t> captureFrameCount{0};
    std::atomic<uint64_t> outputCallbackCount{0};
    std::atomic<uint64_t> outputFrameCount{0};
    std::atomic<uint64_t> formatMismatchCount{0};
    std::atomic<uint64_t> clippedSampleCount{0};
    std::atomic<uint64_t> rejectedGenerationCount{0};
    std::atomic<uint64_t> sourceFatalCount{0};
};

TBAudioRealtimeKernelRef TBAudioRealtimeKernelCreate(
    uint64_t generation,
    const TBAudioRealtimeFormat* sourceFormats,
    uint32_t sourceCount,
    TBAudioRealtimeFormat outputFormat,
    uint32_t targetFrames,
    uint32_t capacityFrames,
    uint32_t rampFrames
) {
    if (sourceFormats == nullptr || sourceCount == 0 || !IsPackedFloat32Stereo(outputFormat)) {
        return nullptr;
    }
    for (uint32_t index = 0; index < sourceCount; ++index) {
        if (!IsPackedFloat32Stereo(sourceFormats[index])
            || !TBAudioSampleRatesCompatible(
                sourceFormats[index].sampleRate, outputFormat.sampleRate
            )) {
            return nullptr;
        }
    }
    try {
        return new TBAudioRealtimeKernel(
            generation, sourceCount, targetFrames, capacityFrames, rampFrames
        );
    } catch (...) {
        return nullptr;
    }
}

void TBAudioRealtimeKernelDestroy(TBAudioRealtimeKernelRef kernel) {
    delete kernel;
}

bool TBAudioRealtimeKernelPushCapture(
    TBAudioRealtimeKernelRef kernel,
    uint64_t generation,
    uint32_t sourceIndex,
    const TBAudioRealtimeInputView* input
) noexcept {
    if (kernel == nullptr) return false;
    if (kernel->attached.load(std::memory_order_acquire) == 0
        || generation != kernel->generation) {
        kernel->rejectedGenerationCount.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    if (sourceIndex >= kernel->sources.size() || !IsValidInput(input)) {
        kernel->formatMismatchCount.fetch_add(1, std::memory_order_relaxed);
        kernel->sourceFatalCount.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    kernel->captureCallbackCount.fetch_add(1, std::memory_order_relaxed);
    kernel->captureFrameCount.fetch_add(input->frameCount, std::memory_order_relaxed);
    kernel->sources[sourceIndex]->ring.Write(
        static_cast<const float*>(input->buffers[0]), input->frameCount
    );
    return true;
}

bool TBAudioRealtimeKernelRenderOutput(
    TBAudioRealtimeKernelRef kernel,
    uint64_t generation,
    TBAudioRealtimeOutputView* output
) noexcept {
    ZeroOutput(output);
    if (kernel == nullptr) return false;
    if (kernel->attached.load(std::memory_order_acquire) == 0
        || generation != kernel->generation) {
        kernel->rejectedGenerationCount.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    if (!IsValidOutput(output)) {
        kernel->formatMismatchCount.fetch_add(1, std::memory_order_relaxed);
        return false;
    }

    kernel->outputCallbackCount.fetch_add(1, std::memory_order_relaxed);
    kernel->outputFrameCount.fetch_add(output->frameCount, std::memory_order_relaxed);
    auto* samples = static_cast<float*>(output->buffers[0]);
    for (const auto& source : kernel->sources) {
        const bool muted = source->muted.load(std::memory_order_acquire) != 0;
        const float targetGain = muted
            ? 0
            : FloatFromBits(source->gainBits.load(std::memory_order_relaxed));
        const uint32_t rampFrames = muted
            ? source->muteRampFrames.load(std::memory_order_relaxed)
            : source->defaultRampFrames;
        source->ring.MixWithRamp(samples, output->frameCount, targetGain, rampFrames);
    }
    kernel->clippedSampleCount.fetch_add(
        TBAudioClamp(samples, output->frameCount * 2), std::memory_order_relaxed
    );
    return true;
}

void TBAudioRealtimeKernelSetSourceGain(
    TBAudioRealtimeKernelRef kernel,
    uint32_t sourceIndex,
    float gain
) {
    if (kernel == nullptr || sourceIndex >= kernel->sources.size()) return;
    const float boundedGain = std::isfinite(gain)
        ? std::min(std::max(gain, 0.0f), 3.0f)
        : 0.0f;
    kernel->sources[sourceIndex]->gainBits.store(
        FloatBits(boundedGain), std::memory_order_relaxed
    );
}

void TBAudioRealtimeKernelBeginSourceMute(
    TBAudioRealtimeKernelRef kernel,
    uint32_t sourceIndex,
    uint32_t rampFrames
) {
    if (kernel == nullptr || sourceIndex >= kernel->sources.size()) return;
    kernel->sources[sourceIndex]->muteRampFrames.store(rampFrames, std::memory_order_relaxed);
    kernel->sources[sourceIndex]->muted.store(1, std::memory_order_release);
}

void TBAudioRealtimeKernelDetach(TBAudioRealtimeKernelRef kernel) {
    if (kernel != nullptr) kernel->attached.store(0, std::memory_order_release);
}

bool TBAudioRealtimeKernelCopySnapshot(
    TBAudioRealtimeKernelRef kernel,
    TBAudioRealtimeSnapshot* snapshot
) {
    if (kernel == nullptr || snapshot == nullptr) return false;
    TBAudioRealtimeSnapshot value{};
    value.captureCallbackCount = kernel->captureCallbackCount.load(std::memory_order_relaxed);
    value.captureFrameCount = kernel->captureFrameCount.load(std::memory_order_relaxed);
    value.outputCallbackCount = kernel->outputCallbackCount.load(std::memory_order_relaxed);
    value.outputFrameCount = kernel->outputFrameCount.load(std::memory_order_relaxed);
    value.formatMismatchCount = kernel->formatMismatchCount.load(std::memory_order_relaxed);
    value.clippedSampleCount = kernel->clippedSampleCount.load(std::memory_order_relaxed);
    value.rejectedGenerationCount = kernel->rejectedGenerationCount.load(std::memory_order_relaxed);
    value.sourceFatalCount = kernel->sourceFatalCount.load(std::memory_order_relaxed);
    for (const auto& source : kernel->sources) {
        value.ringOccupancyFrames += source->ring.OccupancyFrames();
        value.ringHighWaterFrames = std::max(
            value.ringHighWaterFrames, source->ring.HighWaterFrames()
        );
        value.warmupFrameCount += source->ring.WarmupFrames();
        value.underrunFrameCount += source->ring.UnderrunFrames();
        value.overrunFrameCount += source->ring.DroppedFrames();
        value.forcedResyncCount += source->ring.ForcedResyncCount();
        value.nonFiniteSampleCount += source->ring.NonFiniteSamples();
    }
    *snapshot = value;
    return true;
}
