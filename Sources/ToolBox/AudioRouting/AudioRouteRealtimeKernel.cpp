#include "AudioRouteRealtimeKernel.hpp"

#include "AudioRouteDSP.hpp"
#include "AudioRouteRealtime.hpp"
#include "AudioRouteSampleRateConverter.hpp"

#include <AudioToolbox/AudioFormat.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <stdexcept>
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

TBAudioRealtimeFormat CanonicalFormat(double sampleRate) noexcept {
    return TBAudioRealtimeFormat{
        sampleRate,
        kAudioFormatLinearPCM,
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            | kAudioFormatFlagIsNonInterleaved,
        sizeof(float),
        1,
        sizeof(float),
        2,
        32
    };
}

uint32_t MaximumConvertedFrames(
    const TBAudioRealtimeFormat& source,
    const TBAudioRealtimeFormat& destination,
    uint32_t maximumInputFrames
) {
    const double ratio = destination.sampleRate / source.sampleRate;
    if (!std::isfinite(ratio) || ratio < 0.125 || ratio > 8) {
        throw std::invalid_argument("unsupported sample-rate ratio");
    }
    const double frames = std::ceil(maximumInputFrames * ratio) + 32;
    if (frames > UINT32_MAX) throw std::overflow_error("converted frame capacity overflow");
    return static_cast<uint32_t>(frames);
}

size_t CheckedSampleCount(uint32_t frames, uint32_t channels) {
    if (channels != 0
        && static_cast<size_t>(frames) > std::numeric_limits<size_t>::max() / channels) {
        throw std::overflow_error("realtime scratch capacity overflow");
    }
    const size_t sampleCount = static_cast<size_t>(frames) * channels;
    if (sampleCount > std::numeric_limits<size_t>::max() / sizeof(float)) {
        throw std::overflow_error("realtime scratch byte capacity overflow");
    }
    return sampleCount;
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

struct SourceState {
    SourceState(
        TBAudioRealtimeFormat sourceFormat,
        TBAudioRealtimeFormat canonicalFormat,
        uint32_t targetFrames,
        uint32_t capacityFrames,
        uint32_t rampFrames
    )
        : ring(targetFrames, capacityFrames, rampFrames),
          convertedCapacityFrames(MaximumConvertedFrames(
              sourceFormat, canonicalFormat, capacityFrames
          )),
          converter(TBAudioSampleRateConverter::Create(
              sourceFormat,
              canonicalFormat,
              capacityFrames,
              convertedCapacityFrames
          )),
          convertedLeft(std::make_unique<float[]>(CheckedSampleCount(
              convertedCapacityFrames, 1
          ))),
          convertedRight(std::make_unique<float[]>(CheckedSampleCount(
              convertedCapacityFrames, 1
          ))),
          interleaved(std::make_unique<float[]>(CheckedSampleCount(
              convertedCapacityFrames, 2
          ))),
          defaultRampFrames(rampFrames),
          gainBits(FloatBits(1)) {
        if (converter == nullptr) throw std::invalid_argument("unsupported source format");
    }

    bool ConvertAndWrite(const TBAudioRealtimeInputView& input) noexcept {
        TBAudioRealtimeOutputView output{};
        output.buffers[0] = convertedLeft.get();
        output.buffers[1] = convertedRight.get();
        output.byteSizes[0] = convertedCapacityFrames * sizeof(float);
        output.byteSizes[1] = convertedCapacityFrames * sizeof(float);
        output.bufferCount = 2;
        output.frameCount = convertedCapacityFrames;
        if (!converter->Convert(input, output)) return false;
        for (uint32_t frame = 0; frame < output.frameCount; ++frame) {
            interleaved[frame * 2] = convertedLeft[frame];
            interleaved[frame * 2 + 1] = convertedRight[frame];
        }
        ring.Write(interleaved.get(), output.frameCount);
        return true;
    }

    TBAudioStereoRingBuffer ring;
    const uint32_t convertedCapacityFrames;
    std::unique_ptr<TBAudioSampleRateConverter> converter;
    std::unique_ptr<float[]> convertedLeft;
    std::unique_ptr<float[]> convertedRight;
    std::unique_ptr<float[]> interleaved;
    const uint32_t defaultRampFrames;
    std::atomic<uint32_t> gainBits;
    std::atomic<uint32_t> muteRampFrames{0};
    std::atomic<uint32_t> muted{0};
};
}

struct TBAudioRealtimeKernel {
    TBAudioRealtimeKernel(
        uint64_t valueGeneration,
        const TBAudioRealtimeFormat* sourceFormats,
        uint32_t sourceCount,
        TBAudioRealtimeFormat outputFormat,
        uint32_t targetFrames,
        uint32_t capacityFrames,
        uint32_t rampFrames
    ) : generation(valueGeneration),
        capacityFrames(capacityFrames),
        canonicalFormat(CanonicalFormat(outputFormat.sampleRate)),
        outputAdapter(TBAudioSampleRateConverter::Create(
            canonicalFormat, outputFormat, capacityFrames, capacityFrames
        )),
        mixScratch(std::make_unique<float[]>(CheckedSampleCount(capacityFrames, 2))),
        outputLeft(std::make_unique<float[]>(CheckedSampleCount(capacityFrames, 1))),
        outputRight(std::make_unique<float[]>(CheckedSampleCount(capacityFrames, 1))) {
        if (outputFormat.channelsPerFrame != 2 || outputAdapter == nullptr) {
            throw std::invalid_argument("unsupported output format");
        }
        sources.reserve(sourceCount);
        for (uint32_t index = 0; index < sourceCount; ++index) {
            sources.push_back(std::make_unique<SourceState>(
                sourceFormats[index],
                canonicalFormat,
                targetFrames,
                capacityFrames,
                rampFrames
            ));
        }
    }

    const uint64_t generation;
    const uint32_t capacityFrames;
    const TBAudioRealtimeFormat canonicalFormat;
    std::unique_ptr<TBAudioSampleRateConverter> outputAdapter;
    std::unique_ptr<float[]> mixScratch;
    std::unique_ptr<float[]> outputLeft;
    std::unique_ptr<float[]> outputRight;
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
    if (sourceFormats == nullptr || sourceCount == 0) return nullptr;
    try {
        return new TBAudioRealtimeKernel(
            generation,
            sourceFormats,
            sourceCount,
            outputFormat,
            targetFrames,
            capacityFrames,
            rampFrames
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
    if (sourceIndex >= kernel->sources.size() || input == nullptr
        || !kernel->sources[sourceIndex]->ConvertAndWrite(*input)) {
        kernel->formatMismatchCount.fetch_add(1, std::memory_order_relaxed);
        kernel->sourceFatalCount.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    kernel->captureCallbackCount.fetch_add(1, std::memory_order_relaxed);
    kernel->captureFrameCount.fetch_add(input->frameCount, std::memory_order_relaxed);
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
    if (output == nullptr || output->frameCount > kernel->capacityFrames
        || !kernel->outputAdapter->AcceptsOutput(*output)) {
        kernel->formatMismatchCount.fetch_add(1, std::memory_order_relaxed);
        return false;
    }

    kernel->outputCallbackCount.fetch_add(1, std::memory_order_relaxed);
    kernel->outputFrameCount.fetch_add(output->frameCount, std::memory_order_relaxed);
    auto* samples = kernel->mixScratch.get();
    std::fill_n(samples, output->frameCount * 2, 0.0f);
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
    for (uint32_t frame = 0; frame < output->frameCount; ++frame) {
        kernel->outputLeft[frame] = samples[frame * 2];
        kernel->outputRight[frame] = samples[frame * 2 + 1];
    }
    TBAudioRealtimeInputView canonical{};
    canonical.buffers[0] = kernel->outputLeft.get();
    canonical.buffers[1] = kernel->outputRight.get();
    canonical.byteSizes[0] = output->frameCount * sizeof(float);
    canonical.byteSizes[1] = output->frameCount * sizeof(float);
    canonical.bufferCount = 2;
    canonical.frameCount = output->frameCount;
    if (!kernel->outputAdapter->Convert(canonical, *output)) {
        ZeroOutput(output);
        kernel->formatMismatchCount.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
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
