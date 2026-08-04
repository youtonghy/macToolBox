#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

#import "AudioRouteRealtimeKernel.h"

typedef struct TBAudioIOProcLease* TBAudioCallbackLeaseRef;

#ifdef __cplusplus
extern "C" {
#endif

OSStatus TBAudioCreateCaptureIOProc(
    AudioObjectID deviceID,
    TBAudioRealtimeKernelRef _Nonnull kernel,
    uint64_t generation,
    uint32_t sourceIndex,
    AudioDeviceIOProcID _Nullable* _Nonnull outIOProcID,
    TBAudioCallbackLeaseRef _Nullable* _Nonnull outLease
);
OSStatus TBAudioCreateOutputIOProc(
    AudioObjectID deviceID,
    TBAudioRealtimeKernelRef _Nonnull kernel,
    uint64_t generation,
    AudioDeviceIOProcID _Nullable* _Nonnull outIOProcID,
    TBAudioCallbackLeaseRef _Nullable* _Nonnull outLease
);
void TBAudioDetachIOProcLease(TBAudioCallbackLeaseRef _Nullable lease);
uint64_t TBAudioIOProcLeaseInFlight(TBAudioCallbackLeaseRef _Nullable lease);
bool TBAudioDestroyIOProcLease(TBAudioCallbackLeaseRef _Nullable lease);
uint32_t TBAudioCallbackLeasePermanentInUse(void);
uint32_t TBAudioIOProcTeardownDisposition(OSStatus stopStatus, OSStatus destroyStatus);
bool TBAudioObjectDestructionComplete(OSStatus status);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_BEGIN

API_AVAILABLE(macos(14.2))
@interface TBAudioRouteDiagnostics : NSObject

@property(nonatomic, readonly, copy) NSString* routeIdentifier;
@property(nonatomic, readonly) uint64_t captureCallbackCount;
@property(nonatomic, readonly) uint64_t captureFrameCount;
@property(nonatomic, readonly) uint64_t outputCallbackCount;
@property(nonatomic, readonly) uint64_t outputFrameCount;
@property(nonatomic, readonly) uint64_t lastCaptureHostTime;
@property(nonatomic, readonly) uint64_t lastOutputHostTime;
@property(nonatomic, readonly) uint64_t ringOccupancyFrames;
@property(nonatomic, readonly) uint64_t ringHighWaterFrames;
@property(nonatomic, readonly) uint64_t warmupFrameCount;
@property(nonatomic, readonly) uint64_t underrunFrameCount;
@property(nonatomic, readonly) uint64_t overrunFrameCount;
@property(nonatomic, readonly) uint64_t forcedResyncCount;
@property(nonatomic, readonly) uint64_t formatMismatchCount;
@property(nonatomic, readonly) uint64_t nonFiniteSampleCount;
@property(nonatomic, readonly) uint64_t clippedSampleCount;
@property(nonatomic, readonly) uint64_t callbacksInFlight;
@property(nonatomic, readonly) uint64_t sourceFatalCount;
@property(nonatomic, readonly) BOOL fatalCallbackMismatch;

@end

API_AVAILABLE(macos(14.2))
@interface TBAudioRouteEngine : NSObject

- (BOOL)startRouteWithIdentifier:(NSString*)identifier
                 outputDeviceUID:(NSString*)outputDeviceUID
                processObjectIDs:(NSArray<NSNumber*>*)processObjectIDs
                           gains:(NSArray<NSNumber*>*)gains
                           error:(NSError**)error;
- (BOOL)updateGainForRoute:(NSString*)identifier
               sourceIndex:(NSUInteger)sourceIndex
                      gain:(float)gain;
- (void)beginFadeOutRouteWithIdentifier:(NSString*)identifier;
- (void)beginFadeOutAllRoutes;
- (BOOL)stopRouteWithIdentifier:(NSString*)identifier;
- (BOOL)stopAllRoutes;
- (NSArray<TBAudioRouteDiagnostics*>*)diagnostics;
- (BOOL)performMaintenance;
- (BOOL)hasPendingCleanup;
- (void)resetAfterAudioServerRestart;
- (NSTimeInterval)maximumFadeOutDuration;

@end

NS_ASSUME_NONNULL_END
