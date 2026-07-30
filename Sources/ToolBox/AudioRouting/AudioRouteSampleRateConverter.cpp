#include "AudioRouteSampleRateConverter.hpp"

#include <AudioToolbox/AudioFormat.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <new>
#include <stdexcept>
#include <vector>

namespace {
constexpr uint32_t kMaximumBuffers = 2;
constexpr OSStatus kNoInputDataNow = 'ndta';

struct StackAudioBufferList {
    UInt32 numberBuffers = 0;
    AudioBuffer buffers[kMaximumBuffers]{};
};

bool IsNonInterleaved(const TBAudioRealtimeFormat& format) noexcept {
    return (format.formatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
}

uint32_t BufferCount(const TBAudioRealtimeFormat& format) noexcept {
    return IsNonInterleaved(format) ? format.channelsPerFrame : 1;
}

bool IsSupportedPCM(const TBAudioRealtimeFormat& format) noexcept {
    const uint32_t requiredFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    const uint32_t prohibitedFlags = kAudioFormatFlagIsBigEndian
        | kAudioFormatFlagIsSignedInteger
        | kAudioFormatFlagIsAlignedHigh;
    const uint32_t expectedBytesPerFrame = IsNonInterleaved(format)
        ? sizeof(float)
        : format.channelsPerFrame * sizeof(float);
    return std::isfinite(format.sampleRate)
        && format.sampleRate >= 8000
        && format.sampleRate <= 384000
        && format.formatID == kAudioFormatLinearPCM
        && (format.formatFlags & requiredFlags) == requiredFlags
        && (format.formatFlags & prohibitedFlags) == 0
        && format.bytesPerPacket == expectedBytesPerFrame
        && format.framesPerPacket == 1
        && format.bytesPerFrame == expectedBytesPerFrame
        && (format.channelsPerFrame == 1 || format.channelsPerFrame == 2)
        && format.bitsPerChannel == 32;
}

bool CanRepresentBufferSize(
    const TBAudioRealtimeFormat& format,
    uint32_t maximumFrames
) noexcept {
    return static_cast<uint64_t>(maximumFrames) * format.bytesPerFrame <= UINT32_MAX;
}

size_t CheckedSampleCount(uint32_t frames, uint32_t samplesPerFrame) {
    const size_t maximum = std::numeric_limits<size_t>::max();
    if (samplesPerFrame != 0
        && static_cast<size_t>(frames) > maximum / samplesPerFrame) {
        throw std::overflow_error("audio sample capacity overflow");
    }
    const size_t sampleCount = static_cast<size_t>(frames) * samplesPerFrame;
    if (sampleCount > maximum / sizeof(float)) {
        throw std::overflow_error("audio buffer byte capacity overflow");
    }
    return sampleCount;
}

AudioStreamBasicDescription StreamDescription(
    const TBAudioRealtimeFormat& format
) noexcept {
    AudioStreamBasicDescription description{};
    description.mSampleRate = format.sampleRate;
    description.mFormatID = format.formatID;
    description.mFormatFlags = format.formatFlags;
    description.mBytesPerPacket = format.bytesPerPacket;
    description.mFramesPerPacket = format.framesPerPacket;
    description.mBytesPerFrame = format.bytesPerFrame;
    description.mChannelsPerFrame = format.channelsPerFrame;
    description.mBitsPerChannel = format.bitsPerChannel;
    return description;
}

template <typename View>
bool IsValidView(
    const View& view,
    const TBAudioRealtimeFormat& format,
    uint32_t maximumFrames,
    bool requiresExactByteSize
) noexcept {
    const uint32_t count = BufferCount(format);
    if (view.bufferCount != count || view.frameCount > maximumFrames) return false;
    const uint64_t requiredBytes = static_cast<uint64_t>(view.frameCount)
        * format.bytesPerFrame;
    for (uint32_t index = 0; index < count; ++index) {
        if (view.frameCount != 0 && view.buffers[index] == nullptr) return false;
        if (requiresExactByteSize
            ? view.byteSizes[index] != requiredBytes
            : view.byteSizes[index] < requiredBytes) {
            return false;
        }
    }
    return true;
}

void PopulateAudioBufferList(
    StackAudioBufferList& list,
    const TBAudioRealtimeInputView& view,
    const TBAudioRealtimeFormat& format
) noexcept {
    list.numberBuffers = BufferCount(format);
    const uint32_t channelsPerBuffer = IsNonInterleaved(format)
        ? 1
        : format.channelsPerFrame;
    for (uint32_t index = 0; index < list.numberBuffers; ++index) {
        list.buffers[index].mNumberChannels = channelsPerBuffer;
        list.buffers[index].mDataByteSize = view.byteSizes[index];
        list.buffers[index].mData = const_cast<void*>(view.buffers[index]);
    }
}

void PopulateAudioBufferList(
    StackAudioBufferList& list,
    TBAudioRealtimeOutputView& view,
    const TBAudioRealtimeFormat& format
) noexcept {
    list.numberBuffers = BufferCount(format);
    const uint32_t channelsPerBuffer = IsNonInterleaved(format)
        ? 1
        : format.channelsPerFrame;
    for (uint32_t index = 0; index < list.numberBuffers; ++index) {
        list.buffers[index].mNumberChannels = channelsPerBuffer;
        list.buffers[index].mDataByteSize = view.byteSizes[index];
        list.buffers[index].mData = view.buffers[index];
    }
}

struct InputContext {
    StackAudioBufferList list;
    uint32_t frameCount = 0;
    bool supplied = false;
};

OSStatus SupplyInput(
    AudioConverterRef,
    UInt32* packetCount,
    AudioBufferList* data,
    AudioStreamPacketDescription** packetDescriptions,
    void* userData
) noexcept {
    auto* context = static_cast<InputContext*>(userData);
    if (packetDescriptions != nullptr) *packetDescriptions = nullptr;
    if (context == nullptr || packetCount == nullptr || data == nullptr || context->supplied) {
        if (packetCount != nullptr) *packetCount = 0;
        return kNoInputDataNow;
    }
    context->supplied = true;
    *packetCount = context->frameCount;
    data->mNumberBuffers = context->list.numberBuffers;
    for (uint32_t index = 0; index < context->list.numberBuffers; ++index) {
        data->mBuffers[index] = context->list.buffers[index];
    }
    return noErr;
}

float ReadSample(
    const TBAudioRealtimeInputView& input,
    const TBAudioRealtimeFormat& format,
    uint32_t frame,
    uint32_t channel
) noexcept {
    if (IsNonInterleaved(format)) {
        return static_cast<const float*>(input.buffers[channel])[frame];
    }
    return static_cast<const float*>(input.buffers[0])[
        frame * format.channelsPerFrame + channel
    ];
}

void WriteSample(
    TBAudioRealtimeOutputView& output,
    const TBAudioRealtimeFormat& format,
    uint32_t frame,
    uint32_t channel,
    float sample
) noexcept {
    if (IsNonInterleaved(format)) {
        static_cast<float*>(output.buffers[channel])[frame] = sample;
    } else {
        static_cast<float*>(output.buffers[0])[
            frame * format.channelsPerFrame + channel
        ] = sample;
    }
}
}

TBAudioSampleRateConverter::TBAudioSampleRateConverter(
    TBAudioRealtimeFormat source,
    TBAudioRealtimeFormat destination,
    uint32_t maximumInputFrames,
    uint32_t maximumOutputFrames
) noexcept
    : source_(source),
      destination_(destination),
      maximumInputFrames_(maximumInputFrames),
      maximumOutputFrames_(maximumOutputFrames) {}

TBAudioSampleRateConverter::~TBAudioSampleRateConverter() {
    if (converter_ != nullptr) AudioConverterDispose(converter_);
}

std::unique_ptr<TBAudioSampleRateConverter> TBAudioSampleRateConverter::Create(
    const TBAudioRealtimeFormat& source,
    const TBAudioRealtimeFormat& destination,
    uint32_t maximumInputFrames,
    uint32_t maximumOutputFrames
) {
    if (!IsSupportedPCM(source) || !IsSupportedPCM(destination)
        || maximumInputFrames == 0 || maximumOutputFrames == 0
        || !CanRepresentBufferSize(source, maximumInputFrames)
        || !CanRepresentBufferSize(destination, maximumOutputFrames)) {
        return nullptr;
    }
    auto result = std::unique_ptr<TBAudioSampleRateConverter>(
        new TBAudioSampleRateConverter(
            source, destination, maximumInputFrames, maximumOutputFrames
        )
    );
    if (!result->ConfigureAndPrewarm()) return nullptr;
    return result;
}

bool TBAudioSampleRateConverter::ConfigureAndPrewarm() {
    if (source_.sampleRate == destination_.sampleRate) return true;

    const uint32_t sourceBuffers = BufferCount(source_);
    const uint32_t sourceSamplesPerFrame = IsNonInterleaved(source_)
        ? 1
        : source_.channelsPerFrame;
    for (uint32_t slot = 0; slot < 2; ++slot) {
        for (uint32_t index = 0; index < sourceBuffers; ++index) {
            inputStorage_[slot][index] = std::make_unique<float[]>(
                CheckedSampleCount(maximumInputFrames_, sourceSamplesPerFrame)
            );
        }
    }

    const AudioStreamBasicDescription sourceDescription = StreamDescription(source_);
    const AudioStreamBasicDescription destinationDescription = StreamDescription(destination_);
    if (AudioConverterNew(
            &sourceDescription, &destinationDescription, &converter_
        ) != noErr || converter_ == nullptr) {
        return false;
    }

    UInt32 quality = kAudioConverterQuality_High;
    UInt32 complexity = kAudioConverterSampleRateConverterComplexity_MinimumPhase;
    UInt32 primeMethod = kConverterPrimeMethod_None;
    if (AudioConverterSetProperty(
            converter_,
            kAudioConverterSampleRateConverterQuality,
            sizeof(quality),
            &quality
        ) != noErr
        || AudioConverterSetProperty(
            converter_,
            kAudioConverterSampleRateConverterComplexity,
            sizeof(complexity),
            &complexity
        ) != noErr
        || AudioConverterSetProperty(
            converter_,
            kAudioConverterPrimeMethod,
            sizeof(primeMethod),
            &primeMethod
        ) != noErr) {
        return false;
    }

    std::vector<float> sourceStorage[kMaximumBuffers];
    std::vector<float> destinationStorage[kMaximumBuffers];
    const uint32_t destinationBuffers = BufferCount(destination_);
    for (uint32_t index = 0; index < sourceBuffers; ++index) {
        const uint32_t samplesPerFrame = IsNonInterleaved(source_)
            ? 1
            : source_.channelsPerFrame;
        sourceStorage[index].resize(CheckedSampleCount(
            maximumInputFrames_, samplesPerFrame
        ));
    }
    for (uint32_t index = 0; index < destinationBuffers; ++index) {
        const uint32_t samplesPerFrame = IsNonInterleaved(destination_)
            ? 1
            : destination_.channelsPerFrame;
        destinationStorage[index].resize(CheckedSampleCount(
            maximumOutputFrames_, samplesPerFrame
        ));
    }

    TBAudioRealtimeInputView input{};
    input.bufferCount = sourceBuffers;
    input.frameCount = maximumInputFrames_;
    for (uint32_t index = 0; index < sourceBuffers; ++index) {
        input.buffers[index] = sourceStorage[index].data();
        input.byteSizes[index] = static_cast<uint32_t>(
            sourceStorage[index].size() * sizeof(float)
        );
    }
    TBAudioRealtimeOutputView output{};
    output.bufferCount = destinationBuffers;
    output.frameCount = maximumOutputFrames_;
    for (uint32_t index = 0; index < destinationBuffers; ++index) {
        output.buffers[index] = destinationStorage[index].data();
        output.byteSizes[index] = static_cast<uint32_t>(
            destinationStorage[index].size() * sizeof(float)
        );
    }
    if (!ConvertWithAudioConverter(input, output)
        || AudioConverterReset(converter_) != noErr) {
        return false;
    }
    pendingOutputFrames_ = 0;
    nextInputStorageSlot_ = 0;
    return true;
}

bool TBAudioSampleRateConverter::Convert(
    const TBAudioRealtimeInputView& input,
    TBAudioRealtimeOutputView& output
) noexcept {
    if (!AcceptsInput(input) || !AcceptsOutput(output)) {
        return false;
    }
    if (input.frameCount == 0) {
        output.frameCount = 0;
        return true;
    }
    return IsBypass()
        ? ConvertBypass(input, output)
        : ConvertWithAudioConverter(input, output);
}

bool TBAudioSampleRateConverter::AcceptsInput(
    const TBAudioRealtimeInputView& input
) const noexcept {
    return IsValidView(input, source_, maximumInputFrames_, true);
}

bool TBAudioSampleRateConverter::AcceptsOutput(
    const TBAudioRealtimeOutputView& output
) const noexcept {
    return IsValidView(output, destination_, maximumOutputFrames_, false);
}

bool TBAudioSampleRateConverter::ConvertBypass(
    const TBAudioRealtimeInputView& input,
    TBAudioRealtimeOutputView& output
) noexcept {
    if (output.frameCount < input.frameCount) return false;
    for (uint32_t frame = 0; frame < input.frameCount; ++frame) {
        for (uint32_t channel = 0; channel < destination_.channelsPerFrame; ++channel) {
            const uint32_t sourceChannel = source_.channelsPerFrame == 1
                ? 0
                : std::min(channel, source_.channelsPerFrame - 1);
            WriteSample(
                output,
                destination_,
                frame,
                channel,
                ReadSample(input, source_, frame, sourceChannel)
            );
        }
    }
    output.frameCount = input.frameCount;
    return true;
}

bool TBAudioSampleRateConverter::ConvertWithAudioConverter(
    const TBAudioRealtimeInputView& input,
    TBAudioRealtimeOutputView& output
) noexcept {
    const uint32_t stagedSlot = nextInputStorageSlot_;
    const TBAudioRealtimeInputView stagedInput = StageInput(input, stagedSlot);
    InputContext context{};
    PopulateAudioBufferList(context.list, stagedInput, source_);
    context.frameCount = stagedInput.frameCount;

    StackAudioBufferList outputList{};
    PopulateAudioBufferList(outputList, output, destination_);
    const double exactFrames = static_cast<double>(input.frameCount)
        * destination_.sampleRate / source_.sampleRate
        + pendingOutputFrames_;
    UInt32 outputFrames = std::min<uint32_t>(
        output.frameCount,
        std::max<uint32_t>(1, static_cast<uint32_t>(std::floor(exactFrames)))
    );
    const OSStatus status = AudioConverterFillComplexBuffer(
        converter_,
        SupplyInput,
        &context,
        &outputFrames,
        reinterpret_cast<AudioBufferList*>(&outputList),
        nullptr
    );
    if (context.supplied) nextInputStorageSlot_ = 1 - stagedSlot;
    if (!context.supplied) return false;
    if (status != noErr && status != kNoInputDataNow) return false;
    pendingOutputFrames_ = exactFrames - outputFrames;
    output.frameCount = outputFrames;
    for (uint32_t index = 0; index < outputList.numberBuffers; ++index) {
        output.byteSizes[index] = outputList.buffers[index].mDataByteSize;
    }
    return true;
}

TBAudioRealtimeInputView TBAudioSampleRateConverter::StageInput(
    const TBAudioRealtimeInputView& input,
    uint32_t slot
) noexcept {
    TBAudioRealtimeInputView staged{};
    staged.bufferCount = input.bufferCount;
    staged.frameCount = input.frameCount;
    for (uint32_t index = 0; index < input.bufferCount; ++index) {
        const uint32_t byteSize = input.byteSizes[index];
        std::memcpy(inputStorage_[slot][index].get(), input.buffers[index], byteSize);
        staged.buffers[index] = inputStorage_[slot][index].get();
        staged.byteSizes[index] = byteSize;
    }
    return staged;
}

TBAudioSampleRateConverterRef TBAudioSampleRateConverterCreate(
    TBAudioRealtimeFormat sourceFormat,
    TBAudioRealtimeFormat destinationFormat,
    uint32_t maximumInputFrames,
    uint32_t maximumOutputFrames
) {
    try {
        return TBAudioSampleRateConverter::Create(
            sourceFormat,
            destinationFormat,
            maximumInputFrames,
            maximumOutputFrames
        ).release();
    } catch (...) {
        return nullptr;
    }
}

void TBAudioSampleRateConverterDestroy(TBAudioSampleRateConverterRef converter) {
    delete converter;
}

bool TBAudioSampleRateConverterConvert(
    TBAudioSampleRateConverterRef converter,
    const TBAudioRealtimeInputView* input,
    TBAudioRealtimeOutputView* output
) noexcept {
    return converter != nullptr && input != nullptr && output != nullptr
        && converter->Convert(*input, *output);
}

bool TBAudioSampleRateConverterIsBypass(TBAudioSampleRateConverterRef converter) {
    return converter != nullptr && converter->IsBypass();
}
