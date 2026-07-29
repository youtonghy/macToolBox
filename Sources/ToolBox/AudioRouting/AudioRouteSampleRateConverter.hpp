#pragma once

#include "AudioRouteRealtimeKernel.h"

#include <AudioToolbox/AudioConverter.h>
#include <memory>

struct TBAudioSampleRateConverter final {
    static std::unique_ptr<TBAudioSampleRateConverter> Create(
        const TBAudioRealtimeFormat& source,
        const TBAudioRealtimeFormat& destination,
        uint32_t maximumInputFrames,
        uint32_t maximumOutputFrames
    );

    ~TBAudioSampleRateConverter();

    bool Convert(
        const TBAudioRealtimeInputView& input,
        TBAudioRealtimeOutputView& output
    ) noexcept;
    bool AcceptsInput(const TBAudioRealtimeInputView& input) const noexcept;
    bool AcceptsOutput(const TBAudioRealtimeOutputView& output) const noexcept;
    bool IsBypass() const noexcept { return converter_ == nullptr; }

private:
    TBAudioSampleRateConverter(
        TBAudioRealtimeFormat source,
        TBAudioRealtimeFormat destination,
        uint32_t maximumInputFrames,
        uint32_t maximumOutputFrames
    ) noexcept;

    bool ConfigureAndPrewarm();
    bool ConvertBypass(
        const TBAudioRealtimeInputView& input,
        TBAudioRealtimeOutputView& output
    ) noexcept;
    bool ConvertWithAudioConverter(
        const TBAudioRealtimeInputView& input,
        TBAudioRealtimeOutputView& output
    ) noexcept;
    TBAudioRealtimeInputView StageInput(
        const TBAudioRealtimeInputView& input,
        uint32_t slot
    ) noexcept;

    const TBAudioRealtimeFormat source_;
    const TBAudioRealtimeFormat destination_;
    const uint32_t maximumInputFrames_;
    const uint32_t maximumOutputFrames_;
    std::unique_ptr<float[]> inputStorage_[2][2];
    uint32_t nextInputStorageSlot_ = 0;
    AudioConverterRef converter_ = nullptr;
    double pendingOutputFrames_ = 0;
};
