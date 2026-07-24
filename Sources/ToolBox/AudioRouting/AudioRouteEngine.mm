#import "AudioRouteEngine.h"
#import "AudioRouteCallbackLease.hpp"
#import "AudioRouteDSP.hpp"
#import "AudioRouteFormat.hpp"
#import "AudioRouteRealtime.hpp"

#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/CoreAudio.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <memory>
#include <thread>
#include <vector>

extern "C" uint32_t TBAudioIOProcTeardownDisposition(
    OSStatus stopStatus,
    OSStatus destroyStatus
) {
    const bool stopComplete = stopStatus == noErr
        || stopStatus == kAudioHardwareNotRunningError
        || stopStatus == kAudioHardwareBadObjectError
        || stopStatus == kAudioHardwareBadDeviceError;
    const bool destroyComplete = destroyStatus == noErr
        || destroyStatus == kAudioHardwareBadObjectError
        || destroyStatus == kAudioHardwareBadDeviceError;
    return (stopComplete && destroyComplete ? 1u : 0u) | (destroyComplete ? 2u : 0u);
}

extern "C" int32_t TBAudioRouteStopResult(
    int32_t targetFound,
    int32_t targetStopSucceeded
) {
    return targetFound == 0 || targetStopSucceeded != 0;
}

extern "C" bool TBAudioObjectDestructionComplete(OSStatus status) {
    return status == noErr
        || status == kAudioHardwareBadObjectError
        || status == kAudioHardwareBadDeviceError;
}

namespace {
constexpr NSUInteger kMaximumSources = 32;
constexpr uint32_t kRingCapacityFrames = 1 << 16;

struct SourceContext {
    SourceContext(uint32_t targetFrames, uint32_t gainRampFrames)
        : ring(targetFrames, kRingCapacityFrames, gainRampFrames) {}
    ~SourceContext() {
        if (captureIOProcID == nullptr && callbackLease != nullptr) {
            TBAudioCallbackLease::RecyclePermanentAfterCallbackSourceDestroyed(callbackLease);
        }
    }

    AudioObjectID tapID = kAudioObjectUnknown;
    AudioObjectID aggregateID = kAudioObjectUnknown;
    AudioDeviceIOProcID captureIOProcID = nullptr;
    TBAudioCallbackLease* callbackLease = nullptr;
    TBAudioStereoRingBuffer ring;
    std::atomic<float> gain{1.0f};
    std::atomic<uint64_t> captureCallbackCount{0};
    std::atomic<uint64_t> captureFrameCount{0};
    std::atomic<uint64_t> lastCaptureHostTime{0};
    std::atomic<uint64_t> formatMismatchCount{0};
    std::atomic<bool> fatalCallbackMismatch{false};
    std::atomic<bool> active{true};
    bool aggregateDestroyRequested = false;
};

struct RouteContext {
    ~RouteContext() {
        if (outputIOProcID == nullptr && callbackLease != nullptr) {
            TBAudioCallbackLease::RecyclePermanentAfterCallbackSourceDestroyed(callbackLease);
        }
    }

    AudioObjectID outputDeviceID = kAudioObjectUnknown;
    AudioDeviceIOProcID outputIOProcID = nullptr;
    TBAudioCallbackLease* callbackLease = nullptr;
    std::vector<std::unique_ptr<SourceContext>> sources;
    std::atomic<uint64_t> clippedSamples{0};
    std::atomic<uint64_t> outputCallbackCount{0};
    std::atomic<uint64_t> outputFrameCount{0};
    std::atomic<uint64_t> lastOutputHostTime{0};
    std::atomic<uint64_t> formatMismatchCount{0};
    std::atomic<bool> fatalCallbackMismatch{false};
    std::atomic<bool> active{true};
    uint64_t retirementEpoch = 0;
};

uint64_t HostTime(const AudioTimeStamp* timeStamp) noexcept {
    if (timeStamp == nullptr || (timeStamp->mFlags & kAudioTimeStampHostTimeValid) == 0) return 0;
    return timeStamp->mHostTime;
}

NSError* RouteError(OSStatus status, NSString* operation) {
    return [NSError errorWithDomain:@"com.youtonghy.toolbox.audio-routing"
                               code:status
                           userInfo:@{NSLocalizedDescriptionKey:
                                          [NSString stringWithFormat:@"%@ failed (OSStatus %d).", operation, status]}];
}

OSStatus DeviceIDForUID(NSString* uid, AudioObjectID& deviceID) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    CFStringRef qualifier = (__bridge CFStringRef)uid;
    UInt32 size = sizeof(deviceID);
    deviceID = kAudioObjectUnknown;
    return AudioObjectGetPropertyData(
        kAudioObjectSystemObject, &address, sizeof(qualifier), &qualifier, &size, &deviceID
    );
}

uint32_t GetDeviceUInt32Property(
    AudioObjectID deviceID,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope
) {
    AudioObjectPropertyAddress address = {
        selector, scope, kAudioObjectPropertyElementMain
    };
    UInt32 value = 0;
    UInt32 size = sizeof(value);
    return AudioObjectGetPropertyData(deviceID, &address, 0, nullptr, &size, &value) == noErr
        ? value : 0;
}

OSStatus GetStreamFormats(AudioObjectID deviceID,
                          AudioObjectPropertyScope scope,
                          std::vector<AudioStreamBasicDescription>& formats) {
    AudioObjectPropertyAddress streamsAddress = {
        kAudioDevicePropertyStreams, scope, kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nullptr, &size);
    if (status != noErr) return status;
    std::vector<AudioObjectID> streamIDs(size / sizeof(AudioObjectID));
    if (streamIDs.empty()) return kAudioDeviceUnsupportedFormatError;
    status = AudioObjectGetPropertyData(deviceID, &streamsAddress, 0, nullptr, &size, streamIDs.data());
    if (status != noErr) return status;

    formats.clear();
    formats.reserve(streamIDs.size());
    for (AudioObjectID streamID : streamIDs) {
        AudioObjectPropertyAddress formatAddress = {
            kAudioStreamPropertyVirtualFormat,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        AudioStreamBasicDescription format{};
        size = sizeof(format);
        status = AudioObjectGetPropertyData(streamID, &formatAddress, 0, nullptr, &size, &format);
        if (status != noErr) return status;
        formats.push_back(format);
    }
    return noErr;
}

OSStatus ValidateOutputDevice(AudioObjectID deviceID, Float64& sampleRate) {
    std::vector<AudioStreamBasicDescription> outputs;
    OSStatus status = GetStreamFormats(deviceID, kAudioObjectPropertyScopeOutput, outputs);
    if (status != noErr) return status;
    if (TBAudioOutputFormatCompatibility(outputs.data(), static_cast<uint32_t>(outputs.size()))
        != TBAudioOutputFormatSupported) {
        return kAudioDeviceUnsupportedFormatError;
    }
    sampleRate = outputs.front().mSampleRate;
    return noErr;
}

OSStatus ValidateCaptureDevice(AudioObjectID deviceID, Float64 sampleRate) {
    std::vector<AudioStreamBasicDescription> inputs;
    OSStatus status = GetStreamFormats(deviceID, kAudioObjectPropertyScopeInput, inputs);
    if (status != noErr) return status;
    if (TBAudioOutputFormatCompatibility(inputs.data(), static_cast<uint32_t>(inputs.size()))
            != TBAudioOutputFormatSupported
        || !TBAudioSampleRatesCompatible(inputs.front().mSampleRate, sampleRate)) {
        return kAudioDeviceUnsupportedFormatError;
    }
    return noErr;
}

OSStatus CaptureIOProc(AudioObjectID,
                       const AudioTimeStamp*,
                       const AudioBufferList* input,
                       const AudioTimeStamp* inputTime,
                       AudioBufferList*,
                       const AudioTimeStamp*,
                       void* clientData) noexcept {
    auto* lease = static_cast<TBAudioCallbackLease*>(clientData);
    if (lease == nullptr) return noErr;
    auto* source = static_cast<SourceContext*>(lease->Acquire());
    if (source == nullptr) return noErr;
    TBAudioCallbackLeaseGuard flight(lease);
    if (!source->active.load(std::memory_order_acquire)) return noErr;
    source->captureCallbackCount.fetch_add(1, std::memory_order_relaxed);
    source->lastCaptureHostTime.store(HostTime(inputTime), std::memory_order_relaxed);
    if (input == nullptr || input->mNumberBuffers != 1) {
        source->formatMismatchCount.fetch_add(1, std::memory_order_relaxed);
        source->fatalCallbackMismatch.store(true, std::memory_order_release);
        return noErr;
    }
    const AudioBuffer& buffer = input->mBuffers[0];
    if (buffer.mData == nullptr || buffer.mNumberChannels != 2
        || buffer.mDataByteSize % (2 * sizeof(float)) != 0) {
        source->formatMismatchCount.fetch_add(1, std::memory_order_relaxed);
        source->fatalCallbackMismatch.store(true, std::memory_order_release);
        return noErr;
    }
    const uint32_t frameCount = buffer.mDataByteSize / (2 * sizeof(float));
    source->ring.Write(
        static_cast<const float*>(buffer.mData), frameCount
    );
    source->captureFrameCount.fetch_add(frameCount, std::memory_order_relaxed);
    return noErr;
}

OSStatus OutputIOProc(AudioObjectID,
                      const AudioTimeStamp*,
                      const AudioBufferList*,
                      const AudioTimeStamp*,
                      AudioBufferList* output,
                      const AudioTimeStamp* outputTime,
                      void* clientData) noexcept {
    auto* lease = static_cast<TBAudioCallbackLease*>(clientData);
    if (lease == nullptr) return noErr;
    auto* route = static_cast<RouteContext*>(lease->Acquire());
    if (route == nullptr) {
        if (output != nullptr) {
            for (UInt32 index = 0; index < output->mNumberBuffers; ++index) {
                AudioBuffer& buffer = output->mBuffers[index];
                if (buffer.mData != nullptr) std::memset(buffer.mData, 0, buffer.mDataByteSize);
            }
        }
        return noErr;
    }
    TBAudioCallbackLeaseGuard flight(lease);
    if (!route->active.load(std::memory_order_acquire)) {
        if (output != nullptr) {
            for (UInt32 index = 0; index < output->mNumberBuffers; ++index) {
                AudioBuffer& buffer = output->mBuffers[index];
                if (buffer.mData != nullptr) std::memset(buffer.mData, 0, buffer.mDataByteSize);
            }
        }
        return noErr;
    }
    route->outputCallbackCount.fetch_add(1, std::memory_order_relaxed);
    route->lastOutputHostTime.store(HostTime(outputTime), std::memory_order_relaxed);
    if (output == nullptr) {
        route->formatMismatchCount.fetch_add(1, std::memory_order_relaxed);
        route->fatalCallbackMismatch.store(true, std::memory_order_release);
        return noErr;
    }
    for (UInt32 index = 0; index < output->mNumberBuffers; ++index) {
        AudioBuffer& buffer = output->mBuffers[index];
        if (buffer.mData != nullptr) std::memset(buffer.mData, 0, buffer.mDataByteSize);
    }
    if (output->mNumberBuffers != 1) {
        route->formatMismatchCount.fetch_add(1, std::memory_order_relaxed);
        route->fatalCallbackMismatch.store(true, std::memory_order_release);
        return noErr;
    }
    AudioBuffer& destination = output->mBuffers[0];
    if (destination.mData == nullptr || destination.mNumberChannels != 2
        || destination.mDataByteSize % (2 * sizeof(float)) != 0) {
        route->formatMismatchCount.fetch_add(1, std::memory_order_relaxed);
        route->fatalCallbackMismatch.store(true, std::memory_order_release);
        return noErr;
    }

    auto* samples = static_cast<float*>(destination.mData);
    const uint32_t frameCount = destination.mDataByteSize / (2 * sizeof(float));
    route->outputFrameCount.fetch_add(frameCount, std::memory_order_relaxed);
    for (const auto& source : route->sources) {
        source->ring.Mix(samples, frameCount, source->gain.load(std::memory_order_relaxed));
    }
    route->clippedSamples.fetch_add(
        TBAudioClamp(samples, frameCount * 2), std::memory_order_relaxed
    );
    return noErr;
}

bool StopIOProc(AudioObjectID deviceID, AudioDeviceIOProcID& ioProcID) {
    if (deviceID == kAudioObjectUnknown || ioProcID == nullptr) return true;
    const OSStatus stopStatus = AudioDeviceStop(deviceID, ioProcID);
    const OSStatus destroyStatus = AudioDeviceDestroyIOProcID(deviceID, ioProcID);
    const uint32_t disposition = TBAudioIOProcTeardownDisposition(stopStatus, destroyStatus);
    if ((disposition & 2u) != 0) ioProcID = nullptr;
    return (disposition & 1u) != 0;
}

API_AVAILABLE(macos(14.2))
void BeginFadeOut(RouteContext* route) {
    if (route == nullptr || route->outputIOProcID == nullptr
        || !route->active.load(std::memory_order_acquire)) {
        return;
    }
    for (auto& source : route->sources) {
        source->gain.store(0, std::memory_order_release);
    }
}

API_AVAILABLE(macos(14.2))
bool StopRoute(RouteContext* route) {
    if (route == nullptr) return true;
    for (auto& source : route->sources) {
        source->active.store(false, std::memory_order_release);
        if (source->callbackLease != nullptr) source->callbackLease->Detach();
    }
    route->active.store(false, std::memory_order_release);
    if (route->callbackLease != nullptr) route->callbackLease->Detach();

    bool safeToRetire = true;
    for (auto& source : route->sources) {
        const bool captureStopped = StopIOProc(source->aggregateID, source->captureIOProcID);
        safeToRetire = safeToRetire && captureStopped;
        if (!captureStopped) continue;
        if (source->aggregateID != kAudioObjectUnknown) {
            if (!source->aggregateDestroyRequested) {
                const OSStatus status = AudioHardwareDestroyAggregateDevice(source->aggregateID);
                const bool destroyed = TBAudioObjectDestructionComplete(status);
                safeToRetire = safeToRetire && destroyed;
                source->aggregateDestroyRequested = destroyed;
                if (destroyed && status != noErr) {
                    source->aggregateID = kAudioObjectUnknown;
                }
            }
        }
    }
    safeToRetire = StopIOProc(route->outputDeviceID, route->outputIOProcID) && safeToRetire;
    if (route->callbackLease != nullptr && route->callbackLease->InFlight() != 0) safeToRetire = false;
    for (const auto& source : route->sources) {
        if (source->callbackLease != nullptr && source->callbackLease->InFlight() != 0) safeToRetire = false;
    }
    return safeToRetire;
}
}

@interface TBAudioRouteDiagnostics ()
@property(nonatomic, readwrite, copy) NSString* routeIdentifier;
@property(nonatomic, readwrite) uint64_t captureCallbackCount;
@property(nonatomic, readwrite) uint64_t captureFrameCount;
@property(nonatomic, readwrite) uint64_t outputCallbackCount;
@property(nonatomic, readwrite) uint64_t outputFrameCount;
@property(nonatomic, readwrite) uint64_t lastCaptureHostTime;
@property(nonatomic, readwrite) uint64_t lastOutputHostTime;
@property(nonatomic, readwrite) uint64_t ringOccupancyFrames;
@property(nonatomic, readwrite) uint64_t ringHighWaterFrames;
@property(nonatomic, readwrite) uint64_t warmupFrameCount;
@property(nonatomic, readwrite) uint64_t underrunFrameCount;
@property(nonatomic, readwrite) uint64_t overrunFrameCount;
@property(nonatomic, readwrite) uint64_t forcedResyncCount;
@property(nonatomic, readwrite) uint64_t formatMismatchCount;
@property(nonatomic, readwrite) uint64_t nonFiniteSampleCount;
@property(nonatomic, readwrite) uint64_t clippedSampleCount;
@property(nonatomic, readwrite) uint64_t callbacksInFlight;
@property(nonatomic, readwrite) BOOL fatalCallbackMismatch;
@end

@implementation TBAudioRouteDiagnostics
@end

@interface TBAudioRouteEngine ()
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSValue*>* routes;
@property(nonatomic, strong) NSMutableArray<NSValue*>* quarantinedRoutes;
@property(nonatomic, strong) NSMutableArray<NSValue*>* retiredRoutes;
@property(nonatomic, strong) NSMutableArray<NSValue*>* abandonedAfterAudioServerRestart;
@property(nonatomic) uint64_t controlEpoch;
@end

@implementation TBAudioRouteEngine

- (instancetype)init {
    self = [super init];
    if (self) {
        _routes = [NSMutableDictionary dictionary];
        _quarantinedRoutes = [NSMutableArray array];
        _retiredRoutes = [NSMutableArray array];
        _abandonedAfterAudioServerRestart = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    [self stopAllRoutes];
    constexpr NSUInteger kMaximumDrainAttempts = 100;
    for (NSUInteger attempt = 0; attempt < kMaximumDrainAttempts; ++attempt) {
        [self advanceRetirementEpoch];
        [self retryQuarantinedRoutes];
        if (self.routes.count == 0
            && self.quarantinedRoutes.count == 0
            && self.retiredRoutes.count == 0
            && self.abandonedAfterAudioServerRestart.count == 0) {
            return;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    [self resetAfterAudioServerRestart];
}

- (void)quarantineRoute:(RouteContext*)route {
    if (route != nullptr) [self.quarantinedRoutes addObject:[NSValue valueWithPointer:route]];
}

- (void)retireRoute:(RouteContext*)route {
    if (route == nullptr) return;
    route->retirementEpoch = self.controlEpoch;
    [self.retiredRoutes addObject:[NSValue valueWithPointer:route]];
}

- (void)advanceRetirementEpoch {
    self.controlEpoch += 1;
    NSMutableArray<NSValue*>* remaining = [NSMutableArray array];
    for (NSValue* value in self.retiredRoutes) {
        RouteContext* route = static_cast<RouteContext*>(value.pointerValue);
        bool hasInflightCallbacks = route->callbackLease != nullptr
            && route->callbackLease->InFlight() != 0;
        for (const auto& source : route->sources) {
            hasInflightCallbacks = hasInflightCallbacks
                || (source->callbackLease != nullptr && source->callbackLease->InFlight() != 0);
        }
        if (!hasInflightCallbacks && self.controlEpoch - route->retirementEpoch >= 1) {
            for (const auto& source : route->sources) {
                if (source->aggregateDestroyRequested
                    && source->aggregateID != kAudioObjectUnknown) {
                    AudioObjectPropertyAddress classAddress = {
                        kAudioObjectPropertyClass,
                        kAudioObjectPropertyScopeGlobal,
                        kAudioObjectPropertyElementMain
                    };
                    if (!AudioObjectHasProperty(source->aggregateID, &classAddress)) {
                        source->aggregateID = kAudioObjectUnknown;
                    }
                }
                if (source->aggregateID == kAudioObjectUnknown
                    && source->tapID != kAudioObjectUnknown) {
                    const OSStatus status = AudioHardwareDestroyProcessTap(source->tapID);
                    if (TBAudioObjectDestructionComplete(status)) {
                        source->tapID = kAudioObjectUnknown;
                    }
                }
            }
        }
        const bool allTapsDestroyed = std::all_of(
            route->sources.begin(), route->sources.end(), [](const auto& source) {
                return source->tapID == kAudioObjectUnknown;
            }
        );
        if (!hasInflightCallbacks && allTapsDestroyed
            && self.controlEpoch - route->retirementEpoch >= 2) {
            delete route;
        } else {
            [remaining addObject:value];
        }
    }
    self.retiredRoutes = remaining;

    NSMutableArray<NSValue*>* abandonedRemaining = [NSMutableArray array];
    for (NSValue* value in self.abandonedAfterAudioServerRestart) {
        RouteContext* route = static_cast<RouteContext*>(value.pointerValue);
        bool hasInflightCallbacks = route->callbackLease != nullptr
            && route->callbackLease->InFlight() != 0;
        for (const auto& source : route->sources) {
            hasInflightCallbacks = hasInflightCallbacks
                || (source->callbackLease != nullptr && source->callbackLease->InFlight() != 0);
        }
        if (!hasInflightCallbacks && self.controlEpoch - route->retirementEpoch >= 8) {
            delete route;
        } else {
            [abandonedRemaining addObject:value];
        }
    }
    self.abandonedAfterAudioServerRestart = abandonedRemaining;
}

- (void)retryQuarantinedRoutes {
    NSMutableArray<NSValue*>* remaining = [NSMutableArray array];
    for (NSValue* value in self.quarantinedRoutes) {
        RouteContext* route = static_cast<RouteContext*>(value.pointerValue);
        if (StopRoute(route)) {
            [self retireRoute:route];
        } else {
            [remaining addObject:value];
        }
    }
    self.quarantinedRoutes = remaining;
}

- (BOOL)startRouteWithIdentifier:(NSString*)identifier
                 outputDeviceUID:(NSString*)outputDeviceUID
                processObjectIDs:(NSArray<NSNumber*>*)processObjectIDs
                           gains:(NSArray<NSNumber*>*)gains
                           error:(NSError**)error {
    if (processObjectIDs.count == 0 || processObjectIDs.count != gains.count
        || processObjectIDs.count > kMaximumSources) {
        if (error) *error = RouteError(kAudio_ParamError, @"Validate route");
        return NO;
    }
    for (NSNumber* gain in gains) {
        if (!std::isfinite(gain.floatValue)) {
            if (error) *error = RouteError(kAudio_ParamError, @"Validate route gain");
            return NO;
        }
    }
    [self advanceRetirementEpoch];
    [self retryQuarantinedRoutes];
    if (![self stopRouteWithIdentifier:identifier]) {
        if (error) *error = RouteError(kAudioHardwareUnspecifiedError, @"Stop previous audio route");
        return NO;
    }

    auto route = std::make_unique<RouteContext>();
    OSStatus status = DeviceIDForUID(outputDeviceUID, route->outputDeviceID);
    Float64 outputSampleRate = 0;
    if (status == noErr && route->outputDeviceID == kAudioObjectUnknown) status = kAudioHardwareBadDeviceError;
    if (status == noErr) status = ValidateOutputDevice(route->outputDeviceID, outputSampleRate);
    route->sources.reserve(processObjectIDs.count);

    for (NSUInteger index = 0; status == noErr && index < processObjectIDs.count; ++index) {
        const uint32_t outputBufferFrames = GetDeviceUInt32Property(
            route->outputDeviceID, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal
        );
        const uint32_t outputLatencyFrames = GetDeviceUInt32Property(
            route->outputDeviceID, kAudioDevicePropertyLatency, kAudioDevicePropertyScopeOutput
        );
        const uint32_t outputSafetyFrames = GetDeviceUInt32Property(
            route->outputDeviceID, kAudioDevicePropertySafetyOffset, kAudioDevicePropertyScopeOutput
        );
        const uint32_t targetFrames = TBAudioRecommendedTargetFrames(
            outputBufferFrames, outputLatencyFrames, outputSafetyFrames
        );
        const uint32_t gainRampFrames = std::max<uint32_t>(1, static_cast<uint32_t>(outputSampleRate * 0.010));
        auto source = std::make_unique<SourceContext>(targetFrames, gainRampFrames);
        source->callbackLease = TBAudioCallbackLease::CreatePermanent(source.get());
        if (source->callbackLease == nullptr) {
            status = kAudioHardwareUnspecifiedError;
            route->sources.push_back(std::move(source));
            break;
        }
        CATapDescription* description = [[CATapDescription alloc] initStereoMixdownOfProcesses:@[processObjectIDs[index]]];
        description.name = [NSString stringWithFormat:@"ToolBox %@ %lu", identifier, static_cast<unsigned long>(index)];
        description.privateTap = YES;
        description.muteBehavior = CATapMutedWhenTapped;
        if (@available(macOS 26.0, *)) {
            NSString* restoreKey = @"processRestoreEnabled";
            if ([description respondsToSelector:NSSelectorFromString(restoreKey)]) {
                [description setValue:@YES forKey:restoreKey];
            }
        }

        status = AudioHardwareCreateProcessTap(description, &source->tapID);
        // Private capture aggregate: attach the process tap at create time and pin the
        // destination device as clock only. Do NOT add the physical device as a subdevice
        // here — multiple sources may share one output, and claiming it would collide.
        // (Previously taps were set post-create as bare UUID strings; the property expects
        // CFArray<CFDictionary>, so capture often produced zero frames and gain was a no-op.)
        NSString* aggregateUID = [NSString stringWithFormat:@"com.youtonghy.toolbox.capture.%@", NSUUID.UUID.UUIDString];
        NSString* tapUID = description.UUID.UUIDString;
        NSDictionary* tapEntry = @{
            [NSString stringWithUTF8String:kAudioSubTapUIDKey]: tapUID,
            [NSString stringWithUTF8String:kAudioSubTapDriftCompensationKey]: @YES
        };
        NSMutableDictionary* composition = [NSMutableDictionary dictionaryWithDictionary:@{
            [NSString stringWithUTF8String:kAudioAggregateDeviceNameKey]:
                [NSString stringWithFormat:@"ToolBox Capture %@", identifier],
            [NSString stringWithUTF8String:kAudioAggregateDeviceUIDKey]: aggregateUID,
            [NSString stringWithUTF8String:kAudioAggregateDeviceIsPrivateKey]: @YES,
            [NSString stringWithUTF8String:kAudioAggregateDeviceTapAutoStartKey]: @YES,
            [NSString stringWithUTF8String:kAudioAggregateDeviceTapListKey]: @[tapEntry]
        }];
        if (outputDeviceUID.length > 0) {
            composition[[NSString stringWithUTF8String:kAudioAggregateDeviceClockDeviceKey]] = outputDeviceUID;
        }
        if (status == noErr) {
            status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)composition, &source->aggregateID);
        }
        if (status == noErr) status = ValidateCaptureDevice(source->aggregateID, outputSampleRate);
        if (status == noErr) {
            status = AudioDeviceCreateIOProcID(
                source->aggregateID, CaptureIOProc, source->callbackLease, &source->captureIOProcID
            );
        }
        source->gain.store(gains[index].floatValue, std::memory_order_relaxed);
        route->sources.push_back(std::move(source));
    }

    if (status == noErr) {
        route->callbackLease = TBAudioCallbackLease::CreatePermanent(route.get());
        if (route->callbackLease == nullptr) {
            status = kAudioHardwareUnspecifiedError;
        } else {
            status = AudioDeviceCreateIOProcID(
                route->outputDeviceID, OutputIOProc, route->callbackLease, &route->outputIOProcID
            );
        }
    }
    if (status == noErr) status = AudioDeviceStart(route->outputDeviceID, route->outputIOProcID);
    for (auto& source : route->sources) {
        if (status == noErr) status = AudioDeviceStart(source->aggregateID, source->captureIOProcID);
    }

    if (status != noErr) {
        RouteContext* failed = route.release();
        if (StopRoute(failed)) [self retireRoute:failed]; else [self quarantineRoute:failed];
        if (error) *error = RouteError(status, @"Start audio route");
        return NO;
    }

    RouteContext* retained = route.release();
    self.routes[identifier] = [NSValue valueWithPointer:retained];
    return YES;
}

- (BOOL)updateGainForRoute:(NSString*)identifier sourceIndex:(NSUInteger)sourceIndex gain:(float)gain {
    RouteContext* route = static_cast<RouteContext*>(self.routes[identifier].pointerValue);
    if (route == nullptr || sourceIndex >= route->sources.size() || !std::isfinite(gain)) return NO;
    route->sources[sourceIndex]->gain.store(
        std::min(std::max(gain, 0.0f), 3.0f), std::memory_order_relaxed
    );
    return YES;
}

- (void)beginFadeOutRouteWithIdentifier:(NSString*)identifier {
    RouteContext* route = static_cast<RouteContext*>(self.routes[identifier].pointerValue);
    BeginFadeOut(route);
}

- (void)beginFadeOutAllRoutes {
    for (NSValue* value in self.routes.allValues) {
        BeginFadeOut(static_cast<RouteContext*>(value.pointerValue));
    }
}

- (BOOL)stopRouteWithIdentifier:(NSString*)identifier {
    [self advanceRetirementEpoch];
    [self retryQuarantinedRoutes];
    NSValue* value = self.routes[identifier];
    if (value == nil) return TBAudioRouteStopResult(0, 0);
    RouteContext* route = static_cast<RouteContext*>(value.pointerValue);
    [self.routes removeObjectForKey:identifier];
    const bool stopped = StopRoute(route);
    if (stopped) [self retireRoute:route]; else [self quarantineRoute:route];
    return TBAudioRouteStopResult(1, stopped);
}

- (BOOL)stopAllRoutes {
    [self advanceRetirementEpoch];
    [self retryQuarantinedRoutes];
    for (NSString* identifier in self.routes.allKeys.copy) {
        [self stopRouteWithIdentifier:identifier];
    }
    [self retryQuarantinedRoutes];
    return self.routes.count == 0 && self.quarantinedRoutes.count == 0;
}

- (NSArray<TBAudioRouteDiagnostics*>*)diagnostics {
    NSMutableArray<TBAudioRouteDiagnostics*>* snapshots = [NSMutableArray arrayWithCapacity:self.routes.count];
    for (NSString* identifier in [self.routes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        RouteContext* route = static_cast<RouteContext*>(self.routes[identifier].pointerValue);
        if (route == nullptr) continue;

        TBAudioRouteDiagnostics* snapshot = [[TBAudioRouteDiagnostics alloc] init];
        snapshot.routeIdentifier = identifier;
        snapshot.outputCallbackCount = route->outputCallbackCount.load(std::memory_order_relaxed);
        snapshot.outputFrameCount = route->outputFrameCount.load(std::memory_order_relaxed);
        snapshot.lastOutputHostTime = route->lastOutputHostTime.load(std::memory_order_relaxed);
        snapshot.clippedSampleCount = route->clippedSamples.load(std::memory_order_relaxed);
        snapshot.formatMismatchCount = route->formatMismatchCount.load(std::memory_order_relaxed);
        snapshot.callbacksInFlight = route->callbackLease == nullptr ? 0 : route->callbackLease->InFlight();
        snapshot.fatalCallbackMismatch = route->fatalCallbackMismatch.load(std::memory_order_acquire);

        for (const auto& source : route->sources) {
            snapshot.captureCallbackCount += source->captureCallbackCount.load(std::memory_order_relaxed);
            snapshot.captureFrameCount += source->captureFrameCount.load(std::memory_order_relaxed);
            snapshot.lastCaptureHostTime = std::max(
                snapshot.lastCaptureHostTime,
                source->lastCaptureHostTime.load(std::memory_order_relaxed)
            );
            snapshot.ringOccupancyFrames += source->ring.OccupancyFrames();
            snapshot.ringHighWaterFrames = std::max(
                snapshot.ringHighWaterFrames, source->ring.HighWaterFrames()
            );
            snapshot.warmupFrameCount += source->ring.WarmupFrames();
            snapshot.underrunFrameCount += source->ring.UnderrunFrames();
            snapshot.overrunFrameCount += source->ring.DroppedFrames();
            snapshot.forcedResyncCount += source->ring.ForcedResyncCount();
            snapshot.nonFiniteSampleCount += source->ring.NonFiniteSamples();
            snapshot.formatMismatchCount += source->formatMismatchCount.load(std::memory_order_relaxed);
            snapshot.callbacksInFlight += source->callbackLease == nullptr ? 0 : source->callbackLease->InFlight();
            snapshot.fatalCallbackMismatch = snapshot.fatalCallbackMismatch
                || source->fatalCallbackMismatch.load(std::memory_order_acquire);
        }
        [snapshots addObject:snapshot];
    }
    return snapshots;
}

- (BOOL)performMaintenance {
    [self advanceRetirementEpoch];
    [self retryQuarantinedRoutes];
    return self.retiredRoutes.count > 0
        || self.quarantinedRoutes.count > 0
        || self.abandonedAfterAudioServerRestart.count > 0;
}

- (void)resetAfterAudioServerRestart {
    for (NSValue* value in self.routes.allValues) {
        RouteContext* route = static_cast<RouteContext*>(value.pointerValue);
        route->active.store(false, std::memory_order_release);
        if (route->callbackLease != nullptr) route->callbackLease->Detach();
        route->outputIOProcID = nullptr;
        for (const auto& source : route->sources) {
            source->active.store(false, std::memory_order_release);
            if (source->callbackLease != nullptr) source->callbackLease->Detach();
            source->captureIOProcID = nullptr;
        }
        route->retirementEpoch = self.controlEpoch;
        [self.abandonedAfterAudioServerRestart addObject:value];
    }
    for (NSValue* value in self.quarantinedRoutes) {
        RouteContext* route = static_cast<RouteContext*>(value.pointerValue);
        route->active.store(false, std::memory_order_release);
        if (route->callbackLease != nullptr) route->callbackLease->Detach();
        route->outputIOProcID = nullptr;
        for (const auto& source : route->sources) {
            source->active.store(false, std::memory_order_release);
            if (source->callbackLease != nullptr) source->callbackLease->Detach();
            source->captureIOProcID = nullptr;
        }
        route->retirementEpoch = self.controlEpoch;
        [self.abandonedAfterAudioServerRestart addObject:value];
    }
    for (NSValue* value in self.retiredRoutes) {
        static_cast<RouteContext*>(value.pointerValue)->retirementEpoch = self.controlEpoch;
        [self.abandonedAfterAudioServerRestart addObject:value];
    }
    [self.routes removeAllObjects];
    [self.quarantinedRoutes removeAllObjects];
    [self.retiredRoutes removeAllObjects];
}

@end
