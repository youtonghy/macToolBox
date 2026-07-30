#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#define TB_AUDIO_NOEXCEPT noexcept
#else
#define TB_AUDIO_NOEXCEPT
#endif

typedef struct TBAudioRealtimeKernel* TBAudioRealtimeKernelRef;

typedef struct {
    double sampleRate;
    uint32_t formatID;
    uint32_t formatFlags;
    uint32_t bytesPerPacket;
    uint32_t framesPerPacket;
    uint32_t bytesPerFrame;
    uint32_t channelsPerFrame;
    uint32_t bitsPerChannel;
} TBAudioRealtimeFormat;

typedef struct {
    const void* _Nullable buffers[8];
    uint32_t byteSizes[8];
    uint32_t bufferCount;
    uint32_t frameCount;
} TBAudioRealtimeInputView;

typedef struct {
    void* _Nullable buffers[8];
    uint32_t byteSizes[8];
    uint32_t bufferCount;
    uint32_t frameCount;
} TBAudioRealtimeOutputView;

typedef struct TBAudioSampleRateConverter* TBAudioSampleRateConverterRef;

TBAudioSampleRateConverterRef _Nullable TBAudioSampleRateConverterCreate(
    TBAudioRealtimeFormat sourceFormat,
    TBAudioRealtimeFormat destinationFormat,
    uint32_t maximumInputFrames,
    uint32_t maximumOutputFrames
);
void TBAudioSampleRateConverterDestroy(
    TBAudioSampleRateConverterRef _Nullable converter
);
bool TBAudioSampleRateConverterConvert(
    TBAudioSampleRateConverterRef _Nullable converter,
    const TBAudioRealtimeInputView* _Nullable input,
    TBAudioRealtimeOutputView* _Nullable output
) TB_AUDIO_NOEXCEPT;
bool TBAudioSampleRateConverterIsBypass(
    TBAudioSampleRateConverterRef _Nullable converter
);

typedef struct {
    uint64_t captureCallbackCount;
    uint64_t captureFrameCount;
    uint64_t outputCallbackCount;
    uint64_t outputFrameCount;
    uint64_t ringOccupancyFrames;
    uint64_t ringHighWaterFrames;
    uint64_t warmupFrameCount;
    uint64_t underrunFrameCount;
    uint64_t overrunFrameCount;
    uint64_t forcedResyncCount;
    uint64_t formatMismatchCount;
    uint64_t nonFiniteSampleCount;
    uint64_t clippedSampleCount;
    uint64_t rejectedGenerationCount;
    uint64_t sourceFatalCount;
} TBAudioRealtimeSnapshot;

TBAudioRealtimeKernelRef _Nullable TBAudioRealtimeKernelCreate(
    uint64_t generation,
    const TBAudioRealtimeFormat* _Nonnull sourceFormats,
    uint32_t sourceCount,
    TBAudioRealtimeFormat outputFormat,
    uint32_t targetFrames,
    uint32_t capacityFrames,
    uint32_t rampFrames
);
void TBAudioRealtimeKernelDestroy(TBAudioRealtimeKernelRef _Nullable kernel);
bool TBAudioRealtimeKernelPushCapture(
    TBAudioRealtimeKernelRef _Nullable kernel,
    uint64_t generation,
    uint32_t sourceIndex,
    const TBAudioRealtimeInputView* _Nullable input
) TB_AUDIO_NOEXCEPT;
bool TBAudioRealtimeKernelRenderOutput(
    TBAudioRealtimeKernelRef _Nullable kernel,
    uint64_t generation,
    TBAudioRealtimeOutputView* _Nullable output
) TB_AUDIO_NOEXCEPT;
void TBAudioRealtimeKernelSetSourceGain(
    TBAudioRealtimeKernelRef _Nullable kernel,
    uint32_t sourceIndex,
    float gain
);
void TBAudioRealtimeKernelBeginSourceMute(
    TBAudioRealtimeKernelRef _Nullable kernel,
    uint32_t sourceIndex,
    uint32_t rampFrames
);
void TBAudioRealtimeKernelDetach(TBAudioRealtimeKernelRef _Nullable kernel);
bool TBAudioRealtimeKernelCopySnapshot(
    TBAudioRealtimeKernelRef _Nullable kernel,
    TBAudioRealtimeSnapshot* _Nullable snapshot
);

#ifdef __cplusplus
}
#endif

#undef TB_AUDIO_NOEXCEPT
