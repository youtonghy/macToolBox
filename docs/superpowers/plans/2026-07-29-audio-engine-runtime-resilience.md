# Audio Engine Runtime Resilience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Objective-C++-owned per-app audio route lifecycle with a Swift runtime and a minimal allocation-free C++ realtime kernel so dynamic process-device and audio-format changes recover without sustained noise or permanent muting.

**Architecture:** Keep `AudioRouteEngineControlling`, the rule layer, and UI behavior unchanged. Add a Swift runtime that owns desired state, HAL observation, realization transactions, health evaluation, and recovery; reduce Objective-C++ to Core Audio callback trampolines; keep only generation-fenced PCM conversion, SRC, buffering, mixing, fades, callback leases, and atomics in C++.

**Tech Stack:** Swift 5, Objective-C++, C++17 atomics, Core Audio Process Tap/HAL, AudioToolbox `AudioConverter`, XCTest, XcodeGen, ASan, and TSan.

## Global Constraints

- Deployment target remains macOS 14.0; Process Tap behavior is enabled only on macOS 14.2+.
- Use only public Apple Core Audio interfaces; do not add ACE, ecaudiod, an Audio Server Plug-in, or another private driver path.
- Keep the existing `AudioRouteEngineControlling` interface, rule schema, settings UI, and output-only product scope unchanged.
- Swift owns control state. Swift, Objective-C messaging, locks, allocation, logging, and Task/Actor hops are forbidden inside IOProc callbacks.
- The Objective-C++ bridge may validate `AudioBufferList`, acquire a callback lease, and call the C++ kernel; it may not own route lifecycle state.
- C++ control-thread construction may allocate. Realtime `pushCapture` and `renderOutput` calls must be `noexcept`, lock-free, and allocation-free.
- Every active realization binds an immutable format contract and generation. Mismatched callbacks output silence and report a typed fatal condition.
- A source failure rebuilds or isolates that source without stopping sibling sources on the same output route.
- Failed candidate creation rolls back to a demonstrably safe old realization or releases the Tap and fails closed.
- Do not persist PID, AudioObjectID, Tap ID, Aggregate ID, stream ID, callback pointers, or audio-server generation.
- Replace old implementation as each responsibility migrates. Do not ship a long-lived dual-engine feature flag.
- Design source: `docs/superpowers/specs/2026-07-29-audio-engine-runtime-resilience-design.md`.

---

## File Structure

New Swift modules:

- `AudioRouteRuntimeModels.swift`: immutable intent, format fingerprints, observations, realization keys, typed stages, and failures.
- `AudioRouteHealthEvaluator.swift`: pure counter-delta health policy.
- `AudioRouteRecoveryPolicy.swift`: pure retry budget and recovery-action policy.
- `CoreAudioHAL.swift`: private HAL port, production adapter, listener receipts, and resource transactions.
- `AudioFormatContract.swift`: pure format negotiation and supported layout/channel rules.
- `AudioRouteRuntime.swift`: single control-state owner and realization transaction coordinator.
- `SwiftAudioRouteEngineAdapter.swift`: compatibility adapter for `AudioRouteNativeEngineControlling`.

Native modules:

- `AudioRouteRealtimeKernel.h/.hpp/.cpp`: stable opaque C seam plus C++ realtime implementation.
- `AudioRouteSampleRateConverter.hpp/.cpp`: prewarmed `AudioConverter` adapter hidden inside the kernel.
- `AudioRouteEngine.mm`: progressively reduced to `AudioBufferList` validation and IOProc trampolines.
- `AudioRouteCallbackLease.hpp/.cpp`: retained as generation-safe callback ownership.

Tests:

- Swift pure-policy tests for fingerprints, health, recovery, format negotiation, runtime transactions, and compatibility adapter behavior.
- Native PCM tests through the C seam for generation fencing, layout conversion, SRC quality, fades, resync, and callback retirement.
- Existing service, diagnostics, lifecycle, DSP, and registry tests remain regression coverage until the replaced implementation is deleted.

---

### Task 1: Immutable Runtime Identity and Typed Failure Models

**Files:**
- Create: `Sources/ToolBox/AudioRouting/AudioRouteRuntimeModels.swift`
- Create: `Tests/ToolBoxTests/AudioRouteRuntimeModelsTests.swift`
- Create: `Tests/ToolBoxTests/AudioRouteTestFixtures.swift`
- Reference: `Sources/ToolBox/AudioRouting/AudioRoutingModels.swift`

**Interfaces:**
- Consumes: existing `AudioRoutePlan`, `AudioRouteStopReason`, and `AudioRouteDiagnosticsSnapshot`.
- Produces: `AudioFormatFingerprint`, `HALObservationSnapshot`, `AudioRuntimeIntent`, `RealizationKey`, `HALStage`, `HALResourceKind`, and `AudioRuntimeFailure`.

- [ ] **Step 1: Add failing identity tests**

```swift
func testRealizationKeyChangesWhenObservedTapFormatChanges() {
    let first = AudioRouteTestFixtures.observation(tapSampleRate: 44_100)
    let second = AudioRouteTestFixtures.observation(tapSampleRate: 48_000)

    XCTAssertNotEqual(
        RealizationKey(
            routeID: "output-A",
            intent: AudioRouteTestFixtures.intent(),
            observation: first
        ),
        RealizationKey(
            routeID: "output-A",
            intent: AudioRouteTestFixtures.intent(),
            observation: second
        )
    )
}

func testGainOnlyIntentKeepsGraphFingerprint() {
    let first = AudioRouteTestFixtures.intent(gain: 1)
    let second = AudioRouteTestFixtures.intent(gain: 2)

    XCTAssertEqual(first.graphFingerprint, second.graphFingerprint)
    XCTAssertNotEqual(first.parameterFingerprint, second.parameterFingerprint)
}

func testAudioServerGenerationParticipatesInRealizationIdentity() {
    XCTAssertNotEqual(
        RealizationKey(
            routeID: "output-A",
            intent: AudioRouteTestFixtures.intent(),
            observation: AudioRouteTestFixtures.observation(server: 1)
        ),
        RealizationKey(
            routeID: "output-A",
            intent: AudioRouteTestFixtures.intent(),
            observation: AudioRouteTestFixtures.observation(server: 2)
        )
    )
}
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/AudioRouteRuntimeModelsTests CODE_SIGNING_ALLOWED=NO
```

Expected: compilation fails because the runtime identity types do not exist.

- [ ] **Step 3: Implement normalized, hashable fingerprints**

```swift
struct AudioFormatFingerprint: Hashable, Sendable {
    let sampleRateBits: UInt64
    let formatID: UInt32
    let formatFlags: UInt32
    let bytesPerPacket: UInt32
    let framesPerPacket: UInt32
    let bytesPerFrame: UInt32
    let channelsPerFrame: UInt32
    let bitsPerChannel: UInt32

    var sampleRate: Double { Double(bitPattern: sampleRateBits) }

    init(_ value: AudioStreamBasicDescription) {
        sampleRateBits = value.mSampleRate.bitPattern
        formatID = value.mFormatID
        formatFlags = value.mFormatFlags
        bytesPerPacket = value.mBytesPerPacket
        framesPerPacket = value.mFramesPerPacket
        bytesPerFrame = value.mBytesPerFrame
        channelsPerFrame = value.mChannelsPerFrame
        bitsPerChannel = value.mBitsPerChannel
    }
}

struct HALRouteObservation: Equatable, Sendable {
    let outputDeviceID: AudioObjectID
    let outputFormat: AudioFormatFingerprint
    let processDeviceIDsByObjectID: [UInt32: [AudioObjectID]]
    let tapFormatsByProcessObjectID: [UInt32: AudioFormatFingerprint]
    let aggregateFormatsByProcessObjectID: [UInt32: AudioFormatFingerprint]
}

struct HALObservationSnapshot: Equatable, Sendable {
    let audioServerGeneration: UInt64
    let routesByID: [String: HALRouteObservation]
}

struct AudioRuntimeIntent: Equatable, Sendable {
    let generation: UInt64
    let plansByID: [String: AudioRoutePlan]
    let mutedRouteIDs: Set<String>
    let graphFingerprint: Int
    let parameterFingerprint: Int

    init(
        generation: UInt64,
        plansByID: [String: AudioRoutePlan],
        mutedRouteIDs: Set<String>
    ) {
        self.generation = generation
        self.plansByID = plansByID
        self.mutedRouteIDs = mutedRouteIDs
        graphFingerprint = Self.hashGraph(plansByID)
        parameterFingerprint = Self.hashParameters(plansByID, mutedRouteIDs)
    }
}

struct RealizationKey: Hashable, Sendable {
    let graphFingerprint: Int
    let processDeviceFingerprint: Int
    let outputFormat: AudioFormatFingerprint
    let tapFormatFingerprint: Int
    let aggregateFormatFingerprint: Int
    let audioServerGeneration: UInt64

    init?(
        routeID: String,
        intent: AudioRuntimeIntent,
        observation: HALObservationSnapshot
    )
}
```

Implement `hashGraph`, `hashParameters`, and `RealizationKey.init` by sorting route IDs and process-device IDs before combining values with `Hasher`. Gain and mute parameters must not enter `graphFingerprint`; source IDs, output UID, device configuration generation, and source order must enter it. These fingerprints are transient within one process and are never persisted or compared across launches.

Add shared test fixtures with fixed object IDs and valid Float32 ASBDs so later tasks do not invent incompatible helpers:

```swift
enum AudioRouteTestFixtures {
    static func format(sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    static func intent(
        generation: UInt64 = 1,
        outputUID: String = "output-A",
        gain: Float = 1
    ) -> AudioRuntimeIntent {
        let source = AudioRouteSource(
            bundleID: "com.example.player",
            processObjectID: 42,
            linearGain: gain
        )
        let plan = AudioRoutePlan(outputDeviceUID: outputUID, sources: [source])
        return AudioRuntimeIntent(
            generation: generation,
            plansByID: [plan.id: plan],
            mutedRouteIDs: []
        )
    }

    static func observation(
        server: UInt64 = 1,
        outputUID: String = "output-A",
        tapSampleRate: Double = 48_000,
        outputSampleRate: Double = 48_000,
        processDeviceID: AudioObjectID = 100
    ) -> HALObservationSnapshot {
        HALObservationSnapshot(
            audioServerGeneration: server,
            routesByID: [
                outputUID: HALRouteObservation(
                    outputDeviceID: 200,
                    outputFormat: AudioFormatFingerprint(
                        format(sampleRate: outputSampleRate)
                    ),
                    processDeviceIDsByObjectID: [42: [processDeviceID]],
                    tapFormatsByProcessObjectID: [
                        42: AudioFormatFingerprint(format(sampleRate: tapSampleRate))
                    ],
                    aggregateFormatsByProcessObjectID: [
                        42: AudioFormatFingerprint(format(sampleRate: tapSampleRate))
                    ]
                )
            ]
        )
    }
}
```

- [ ] **Step 4: Add structured failure types**

```swift
enum HALStage: String, Sendable {
    case observe, prepareKernel, createTap, createAggregate, createIOProc
    case startCapture, startOutput, commit, stopIOProc, destroyAggregate, destroyTap
}

enum HALResourceKind: String, Sendable {
    case processTap, aggregateDevice, captureIOProc, outputIOProc, realtimeKernel
}

enum AudioRuntimeFailure: Error, Equatable, Sendable {
    case invalidIntent(String)
    case objectUnavailable(kind: HALResourceKind, id: UInt32)
    case unsupportedFormat(routeID: String, observed: AudioFormatFingerprint)
    case prepareFailed(routeID: String, stage: HALStage, status: OSStatus)
    case commitFailed(
        routeID: String,
        stage: HALStage,
        status: OSStatus,
        rollbackSucceeded: Bool
    )
    case cleanupDeferred(routeID: String, resources: [HALResourceKind])
    case audioServerRestarted
}
```

- [ ] **Step 5: Run focused and existing model tests**

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/AudioRouteRuntimeModelsTests \
  -only-testing:ToolBoxTests/RoutePlanCompilerTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

- [ ] **Step 6: Commit the runtime vocabulary**

```bash
git add Sources/ToolBox/AudioRouting/AudioRouteRuntimeModels.swift \
  Tests/ToolBoxTests/AudioRouteRuntimeModelsTests.swift \
  Tests/ToolBoxTests/AudioRouteTestFixtures.swift
git commit -m "refactor(audio): define runtime realization identity"
```

**Gate 1:** A test demonstrates that unchanged user plans still produce a new `RealizationKey` when process devices, Tap ASBD, Aggregate ASBD, output ASBD, or audio-server generation changes.

---

### Task 2: Pure Health and Recovery Policies

**Files:**
- Create: `Sources/ToolBox/AudioRouting/AudioRouteHealthEvaluator.swift`
- Create: `Sources/ToolBox/AudioRouting/AudioRouteRecoveryPolicy.swift`
- Create: `Tests/ToolBoxTests/AudioRouteHealthEvaluatorTests.swift`
- Create: `Tests/ToolBoxTests/AudioRouteRecoveryPolicyTests.swift`
- Modify: `Tests/ToolBoxTests/AudioRouteTestFixtures.swift`
- Reference: `Sources/ToolBox/AudioRouting/AudioRoutingModels.swift`

**Interfaces:**
- Consumes: consecutive source-level `AudioRouteHealthSample` values, explicit consecutive-window counts, and a monotonic timestamp supplied by the caller.
- Produces: `AudioRouteHealthDecision` and `AudioRouteRecoveryAction`; performs no HAL calls and owns no timer.

- [ ] **Step 1: Write failing health-policy tests**

```swift
func testFormatMismatchRequestsImmediateSourceRebuild() {
    let decision = AudioRouteHealthEvaluator.evaluate(
        current: AudioRouteTestFixtures.healthSample(formatMismatchCount: 1),
        previous: AudioRouteTestFixtures.healthSample(),
        consecutiveStalledTickCount: 0,
        consecutiveNonFiniteTickCount: 0,
        consecutiveOverloadWindowCount: 0
    )
    XCTAssertEqual(decision, .rebuild(.formatContractViolation))
}

func testTwoStalledTicksRequestRebuild() {
    XCTAssertEqual(
        AudioRouteHealthEvaluator.evaluate(
            current: AudioRouteTestFixtures.healthSample(),
            previous: AudioRouteTestFixtures.healthSample(),
            consecutiveStalledTickCount: 1,
            consecutiveNonFiniteTickCount: 0,
            consecutiveOverloadWindowCount: 0
        ),
        .degraded(.callbackStall)
    )
    XCTAssertEqual(
        AudioRouteHealthEvaluator.evaluate(
            current: AudioRouteTestFixtures.healthSample(),
            previous: AudioRouteTestFixtures.healthSample(),
            consecutiveStalledTickCount: 2,
            consecutiveNonFiniteTickCount: 0,
            consecutiveOverloadWindowCount: 0
        ),
        .rebuild(.callbackStall)
    )
}

func testClippingNeverRequestsTopologyRebuild() {
    XCTAssertEqual(
        AudioRouteHealthEvaluator.evaluate(
            current: AudioRouteTestFixtures.healthSample(clippedSampleCount: 20_000),
            previous: AudioRouteTestFixtures.healthSample(),
            consecutiveStalledTickCount: 0,
            consecutiveNonFiniteTickCount: 0,
            consecutiveOverloadWindowCount: 0
        ),
        .observe(.clipping)
    )
}

extension AudioRouteTestFixtures {
    static func healthSample(
    captureFrameCount: UInt64 = 0,
    outputFrameCount: UInt64 = 0,
    formatMismatchCount: UInt64 = 0,
    clippedSampleCount: UInt64 = 0
) -> AudioRouteHealthSample {
        AudioRouteHealthSample(
            captureFrameCount: captureFrameCount,
            outputFrameCount: outputFrameCount,
            underrunFrameCount: 0,
            overrunFrameCount: 0,
            forcedResyncCount: 0,
            formatMismatchCount: formatMismatchCount,
            nonFiniteSampleCount: 0,
            clippedSampleCount: clippedSampleCount,
            outputPeriodFrames: 256,
            sourceIsProducingOutput: true
        )
    }
}
```

- [ ] **Step 2: Run tests and verify missing types fail compilation**

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/AudioRouteHealthEvaluatorTests \
  -only-testing:ToolBoxTests/AudioRouteRecoveryPolicyTests CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement the exact initial thresholds**

```swift
struct AudioRouteHealthPolicy: Equatable, Sendable {
    let watchdogInterval: Duration = .milliseconds(250)
    let stalledTickLimit = 2
    let nonFiniteTickLimit = 2
    let resyncLimitPerSecond: UInt64 = 2
    let overloadPeriodLimit: UInt64 = 2
    let degradedWindowLimit = 2
}

struct AudioRouteHealthSample: Equatable, Sendable {
    let captureFrameCount: UInt64
    let outputFrameCount: UInt64
    let underrunFrameCount: UInt64
    let overrunFrameCount: UInt64
    let forcedResyncCount: UInt64
    let formatMismatchCount: UInt64
    let nonFiniteSampleCount: UInt64
    let clippedSampleCount: UInt64
    let outputPeriodFrames: UInt64
    let sourceIsProducingOutput: Bool
}

enum AudioRouteHealthEvaluator {
    static func evaluate(
        current: AudioRouteHealthSample,
        previous: AudioRouteHealthSample,
        consecutiveStalledTickCount: Int,
        consecutiveNonFiniteTickCount: Int,
        consecutiveOverloadWindowCount: Int,
        policy: AudioRouteHealthPolicy = .init()
    ) -> AudioRouteHealthDecision
}

enum AudioRouteHealthDecision: Equatable, Sendable {
    case healthy
    case observe(AudioRouteHealthReason)
    case degraded(AudioRouteHealthReason)
    case rebuild(AudioRouteHealthReason)
}

enum AudioRouteHealthReason: Equatable, Sendable {
    case formatContractViolation, callbackStall, nonFiniteInput
    case forcedResyncBurst, ringOverload, clipping
}
```

Counter deltas must use wrapping subtraction. A paused source with a progressing output IOProc returns `.healthy` or `.observe`, not `.rebuild`.

- [ ] **Step 4: Implement bounded recovery state**

```swift
struct AudioRouteRecoveryPolicy: Sendable {
    static let retryDelays: [Duration] = [
        .milliseconds(250), .seconds(1), .seconds(4)
    ]
    static let retryWindow: Duration = .seconds(30)

    mutating func action(
        for routeID: String,
        reason: AudioRouteHealthReason,
        now: AudioRouteMonotonicTime
    ) -> AudioRouteRecoveryAction

    mutating func reset(
        routeID: String,
        cause: AudioRouteRecoveryResetCause
    )
}

struct AudioRouteMonotonicTime: Comparable, Sendable {
    let uptimeNanoseconds: UInt64
}

protocol AudioRouteClock: AnyObject {
    var now: AudioRouteMonotonicTime { get }
}

final class SystemAudioRouteClock: AudioRouteClock {
    var now: AudioRouteMonotonicTime {
        AudioRouteMonotonicTime(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }
}

enum AudioRouteRecoveryResetCause: Equatable, Sendable {
    case userIntent, halFingerprint, audioServerGeneration
}

enum AudioRouteRecoveryAction: Equatable, Sendable {
    case retry(after: Duration)
    case failClosed
}
```

Only a new user intent, HAL fingerprint, or audio-server generation resets an exhausted budget.

- [ ] **Step 5: Run policy and existing diagnostics tests**

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/AudioRouteHealthEvaluatorTests \
  -only-testing:ToolBoxTests/AudioRouteRecoveryPolicyTests \
  -only-testing:ToolBoxTests/AudioRouteDiagnosticsTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

- [ ] **Step 6: Commit the pure policies**

```bash
git add Sources/ToolBox/AudioRouting/AudioRouteHealthEvaluator.swift \
  Sources/ToolBox/AudioRouting/AudioRouteRecoveryPolicy.swift \
  Tests/ToolBoxTests/AudioRouteHealthEvaluatorTests.swift \
  Tests/ToolBoxTests/AudioRouteRecoveryPolicyTests.swift \
  Tests/ToolBoxTests/AudioRouteTestFixtures.swift
git commit -m "feat(audio): define bounded route recovery policy"
```

**Gate 2:** All recovery decisions are deterministic pure tests; clipping and legal silence cannot accidentally trigger topology rebuilds.

---

### Task 3: Stable Opaque Realtime Kernel Seam

**Files:**
- Create: `Sources/ToolBox/AudioRouting/AudioRouteRealtimeKernel.h`
- Create: `Sources/ToolBox/AudioRouting/AudioRouteRealtimeKernel.hpp`
- Create: `Sources/ToolBox/AudioRouting/AudioRouteRealtimeKernel.cpp`
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteEngine.mm`
- Modify: `Sources/ToolBox/DisplayControl/Darwin/DisplayControlBridgingHeader.h`
- Modify: `Tests/ToolBoxTests/AudioRouteRealtimeTests.swift`
- Modify: `Tests/ToolBoxTests/AudioRouteLifecycleTests.swift`

**Interfaces:**
- Consumes: immutable source/output format descriptors, generation, precomputed capacities, and callback buffer views.
- Produces: opaque `TBAudioRealtimeKernelRef`, generation-fenced push/render calls, atomic parameter updates, mute envelopes, and snapshots.

- [ ] **Step 1: Add failing generation and source-isolation tests**

```swift
func testStaleGenerationCaptureIsRejected() throws {
    let kernel = try makeKernel(generation: 7, sourceCount: 1)
    defer { TBAudioRealtimeKernelDestroy(kernel) }

    XCTAssertFalse(pushStereo(kernel, generation: 6, source: 0, value: 1))
    XCTAssertEqual(
        renderStereo(kernel, generation: 7, frames: 4),
        [Float](repeating: 0, count: 8)
    )
}

func testMutingOneSourceKeepsSiblingAudible() throws {
    let kernel = try makeKernel(generation: 7, sourceCount: 2)
    pushStereo(kernel, generation: 7, source: 0, value: 0.25)
    pushStereo(kernel, generation: 7, source: 1, value: 0.50)
    TBAudioRealtimeKernelBeginSourceMute(kernel, 0, 0)

    XCTAssertEqual(
        renderStereo(kernel, generation: 7, frames: 4),
        [Float](repeating: 0.50, count: 8)
    )
}
```

Implement `makeKernel`, `pushStereo`, and `renderStereo` in the test file as thin wrappers around the C functions defined in Step 3. They must construct packed Float32 stereo `TBAudioRealtimeFormat` values and C buffer views inside `withUnsafeBytes`/`withUnsafeMutableBytes`; they must not introduce a second test-only PCM implementation.

- [ ] **Step 2: Run realtime tests and verify the C seam is missing**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/AudioRouteRealtimeTests \
  -only-testing:ToolBoxTests/AudioRouteLifecycleTests CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Define the stable C interface**

```c
typedef struct TBAudioRealtimeKernel* TBAudioRealtimeKernelRef;

typedef struct {
    double sampleRate;
    uint32_t formatID;
    uint32_t formatFlags;
    uint32_t bytesPerFrame;
    uint32_t channelsPerFrame;
    uint32_t bitsPerChannel;
} TBAudioRealtimeFormat;

typedef struct {
    const void* buffers[8];
    uint32_t byteSizes[8];
    uint32_t bufferCount;
    uint32_t frameCount;
} TBAudioRealtimeInputView;

typedef struct {
    void* buffers[8];
    uint32_t byteSizes[8];
    uint32_t bufferCount;
    uint32_t frameCount;
} TBAudioRealtimeOutputView;

TBAudioRealtimeKernelRef _Nullable TBAudioRealtimeKernelCreate(
    uint64_t generation,
    const TBAudioRealtimeFormat* sourceFormats,
    uint32_t sourceCount,
    TBAudioRealtimeFormat outputFormat,
    uint32_t targetFrames,
    uint32_t capacityFrames,
    uint32_t rampFrames
);
void TBAudioRealtimeKernelDestroy(TBAudioRealtimeKernelRef kernel);
bool TBAudioRealtimeKernelPushCapture(
    TBAudioRealtimeKernelRef kernel,
    uint64_t generation,
    uint32_t sourceIndex,
    const TBAudioRealtimeInputView* input
);
bool TBAudioRealtimeKernelRenderOutput(
    TBAudioRealtimeKernelRef kernel,
    uint64_t generation,
    TBAudioRealtimeOutputView* output
);
void TBAudioRealtimeKernelSetSourceGain(
    TBAudioRealtimeKernelRef kernel, uint32_t sourceIndex, float gain
);
void TBAudioRealtimeKernelBeginSourceMute(
    TBAudioRealtimeKernelRef kernel, uint32_t sourceIndex, uint32_t rampFrames
);
void TBAudioRealtimeKernelDetach(TBAudioRealtimeKernelRef kernel);
```

Add a POD `TBAudioRealtimeSnapshot` containing the existing counters plus rejected generation and source-fatal counters.

- [ ] **Step 4: Move existing ring/mix behavior behind the new seam**

The first implementation accepts the existing interleaved packed Float32 stereo contract and delegates to the existing `TBAudioStereoRingBuffer`. Unsupported views return `false`, zero output, and increment format mismatch. Do not add SRC in this task.

- [ ] **Step 5: Make `AudioRouteEngine.mm` call only the opaque kernel from IOProc**

```objc
const TBAudioRealtimeInputView view = TBMakeInputView(input);
if (!TBAudioRealtimeKernelPushCapture(
        source->kernel, source->generation, source->sourceIndex, &view)) {
    source->formatMismatchCount.fetch_add(1, std::memory_order_relaxed);
}
```

No callback may dereference a Swift object or call an Objective-C method.

- [ ] **Step 6: Run realtime, DSP, and lifecycle tests**

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/AudioRouteRealtimeTests \
  -only-testing:ToolBoxTests/AudioRouteDSPTests \
  -only-testing:ToolBoxTests/AudioRouteLifecycleTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS with PCM behavior unchanged for the existing supported format.

- [ ] **Step 7: Run native safety tests**

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -enableAddressSanitizer YES \
  -only-testing:ToolBoxTests/AudioRouteRealtimeTests \
  -only-testing:ToolBoxTests/AudioRouteLifecycleTests CODE_SIGNING_ALLOWED=NO

xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -enableThreadSanitizer YES \
  -only-testing:ToolBoxTests/AudioRouteRealtimeTests \
  -only-testing:ToolBoxTests/AudioRouteLifecycleTests CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 8: Commit the realtime seam**

```bash
git add Sources/ToolBox/AudioRouting/AudioRouteRealtimeKernel.* \
  Sources/ToolBox/AudioRouting/AudioRouteEngine.mm \
  Sources/ToolBox/DisplayControl/Darwin/DisplayControlBridgingHeader.h \
  Tests/ToolBoxTests/AudioRouteRealtimeTests.swift \
  Tests/ToolBoxTests/AudioRouteLifecycleTests.swift
git commit -m "refactor(audio): add generation-fenced realtime kernel"
```

**Gate 3:** Existing PCM behavior remains green, stale callbacks produce silence, one source can mute independently, and ASan/TSan report no callback lifetime failure.

---

### Task 4: Swift Runtime Skeleton and Scripted HAL Port

**Files:**
- Create: `Sources/ToolBox/AudioRouting/CoreAudioHAL.swift`
- Create: `Sources/ToolBox/AudioRouting/AudioRouteRuntime.swift`
- Create: `Sources/ToolBox/AudioRouting/SwiftAudioRouteEngineAdapter.swift`
- Create: `Tests/ToolBoxTests/AudioRouteRuntimeTests.swift`
- Create: `Tests/ToolBoxTests/SwiftAudioRouteEngineAdapterTests.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteController.swift`

**Interfaces:**
- Consumes: Task 1 models, Task 2 policies, existing `AudioRouteNativeEngineControlling`, and existing native plans/parameters.
- Produces: private `CoreAudioHALPort`, `AudioRouteRuntimeControlling`, `ScriptedCoreAudioHAL` test adapter, and production compatibility adapter without changing the outer engine interface.

- [ ] **Step 1: Write failing runtime idempotency and rollback tests**

```swift
func testSameIntentAndObservationIsIdempotent() throws {
    let hal = ScriptedCoreAudioHAL(observation: AudioRouteTestFixtures.observation())
    let runtime = AudioRouteRuntime(hal: hal)

    XCTAssertEqual(try runtime.converge(to: AudioRouteTestFixtures.intent()), .applied)
    XCTAssertEqual(try runtime.converge(to: AudioRouteTestFixtures.intent()), .unchanged)
    XCTAssertEqual(hal.executedTransactions.count, 1)
}

func testChangedTapFormatRebuildsUnchangedIntent() throws {
    let hal = ScriptedCoreAudioHAL(
        observation: AudioRouteTestFixtures.observation(tapSampleRate: 44_100)
    )
    let runtime = AudioRouteRuntime(hal: hal)
    _ = try runtime.converge(to: AudioRouteTestFixtures.intent())

    hal.observation = AudioRouteTestFixtures.observation(tapSampleRate: 48_000)

    XCTAssertEqual(try runtime.converge(to: AudioRouteTestFixtures.intent()), .applied)
    XCTAssertEqual(hal.executedTransactions.count, 2)
}

func testCandidateFailureKeepsSafePreviousRealization() throws {
    let hal = ScriptedCoreAudioHAL(observation: AudioRouteTestFixtures.observation())
    let runtime = AudioRouteRuntime(hal: hal)
    _ = try runtime.converge(to: AudioRouteTestFixtures.intent(outputUID: "output-A"))
    hal.failNext(stage: .startCapture, status: -1)
    hal.observation = AudioRouteTestFixtures.observation(outputUID: "output-B")

    XCTAssertThrowsError(
        try runtime.converge(to: AudioRouteTestFixtures.intent(outputUID: "output-B"))
    )
    XCTAssertEqual(hal.activeOutputUIDs, ["output-A"])
}
```

- [ ] **Step 2: Run tests and verify the runtime is missing**

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/AudioRouteRuntimeTests \
  -only-testing:ToolBoxTests/SwiftAudioRouteEngineAdapterTests CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Define the private HAL port and receipts**

```swift
protocol CoreAudioHALPort: AnyObject {
    func observe(_ request: HALObservationRequest) throws -> HALObservationSnapshot
    func execute(_ transaction: HALTransaction) throws -> HALTransactionReceipt
    func changes(for observations: Set<HALObservation>) -> AsyncStream<HALChange>
}

struct HALObservationRequest: Equatable, Sendable {
    let intent: AudioRuntimeIntent
}

enum HALObservation: Hashable, Sendable {
    case processDevices(AudioObjectID)
    case tapFormat(AudioObjectID)
    case aggregateInputStreams(AudioObjectID)
    case aggregateInputFormat(AudioObjectID)
    case outputAlive(AudioObjectID)
    case outputStreams(AudioObjectID)
    case outputNominalRate(AudioObjectID)
    case outputStreamFormat(AudioObjectID)
    case audioServerGeneration
}

enum HALChange: Equatable, Sendable {
    case propertyChanged
    case audioServerRestarted
}

enum HALTransactionKind: Equatable, Sendable {
    case muteOld, fadeOldToZero, prepareCandidate, startCandidateCapture
    case prerollCandidate, commitCandidate, fadeInCandidate, detachOld
    case stopOldCapture, drainOldCallbacks, destroyOld, destroyTap, shutdown
}

struct HALTransaction: Sendable {
    let kind: HALTransactionKind
    let routeID: String
    let sourceIDs: [UInt32]
    let intent: AudioRuntimeIntent
    let observation: HALObservationSnapshot
    let replacingKeysByRouteID: [String: RealizationKey]
}

enum HALRollbackResult: Equatable, Sendable {
    case succeeded
    case deferred(resources: [HALResourceKind])
}

struct HALTransactionReceipt: @unchecked Sendable {
    let realizedKeysByRouteID: [String: RealizationKey]
    let activeOutputUIDs: Set<String>
    let rollback: @Sendable () -> HALRollbackResult
}

enum AudioRuntimeApplyResult: Equatable, Sendable {
    case applied
    case unchanged
}

enum HALCapability: Hashable, Sendable {
    case parallelCapture
}

enum HALOperation: Equatable, Sendable {
    case muteOld(UInt32), fadeOldToZero(UInt32)
    case prepareCandidate(UInt32), startCandidateCapture(UInt32)
    case prerollCandidate(UInt32), commitCandidate(UInt32)
    case fadeInCandidate(UInt32), detachOld(UInt32)
    case stopOldCapture(UInt32), drainOldCallbacks(UInt32)
    case destroyOld(UInt32), destroyTap(UInt32)
}

protocol AudioRouteRuntimeControlling: AnyObject {
    func converge(to intent: AudioRuntimeIntent) throws -> AudioRuntimeApplyResult
    func snapshot() -> [AudioRouteDiagnosticsSnapshot]
    func shutdown(reason: AudioRouteStopReason) -> AudioRouteStopReport
}
```

The production runtime remains unwired in this task. Implement this test adapter in `AudioRouteRuntimeTests.swift`:

```swift
final class ScriptedCoreAudioHAL: CoreAudioHALPort {
    var observation: HALObservationSnapshot
    let capabilities: Set<HALCapability>
    private(set) var executedTransactions: [HALTransaction] = []
    var operationLog: [HALOperation] = []
    private(set) var activeOutputUIDs: Set<String> = []
    private(set) var activeSourceIDs: Set<UInt32> = []

    init(
        observation: HALObservationSnapshot,
        capabilities: Set<HALCapability> = []
    )

    func observe(_ request: HALObservationRequest) throws -> HALObservationSnapshot
    func execute(_ transaction: HALTransaction) throws -> HALTransactionReceipt
    func changes(for observations: Set<HALObservation>) -> AsyncStream<HALChange>

    func failNext(stage: HALStage, status: OSStatus)
    func failNext(sourceID: UInt32, stage: HALStage)
    func failEveryTransaction(sourceID: UInt32, stage: HALStage)
    func setHealthSample(_ sourceID: UInt32, _ sample: AudioRouteHealthSample)
}
```

`observe` returns `observation`. `execute` appends the transaction and either applies its source/output IDs or throws the configured typed failure. `changes` yields values sent through a test-only continuation. Failure injection and health samples are test controls, not `CoreAudioHALPort` requirements.

- [ ] **Step 4: Implement the runtime state owner**

`AudioRouteRuntime` stores only `desiredIntent`, active realization records, `RealizationKey`s, pending cleanup receipts, and recovery state. It compares complete intent plus fresh observation, prepares candidates, commits only complete receipts, and retains structured failures in diagnostics.

- [ ] **Step 5: Implement the compatibility adapter**

`SwiftAudioRouteEngineAdapter` conforms to the existing `AudioRouteNativeEngineControlling`. It reconstructs complete desired plans from changed/removing routes. `beginFadeOut` changes the stored intent's `mutedRouteIDs` and calls `converge`; any failure is retained and thrown by the next `reconcile`.

```swift
final class SwiftAudioRouteEngineAdapter: AudioRouteNativeEngineControlling {
    private let runtime: any AudioRouteRuntimeControlling
    private var plansByID: [String: AudioRoutePlan] = [:]
    private var pendingFailure: Error?

    func beginFadeOut(routeIDs: [String])
    func beginFadeOutAll()
    func reconcile(
        changedPlans: [AudioRoutePlan],
        removingRouteIDs: [String],
        retainedParameters: [AudioRouteNativeRuntimeParameters]
    ) throws
    func update(parameters: [AudioRouteNativeRuntimeParameters]) throws
    func diagnostics() -> [AudioRouteDiagnosticsSnapshot]
    func performMaintenance() -> Bool
    func stopAll(reason: AudioRouteStopReason) -> AudioRouteStopReport
}
```

- [ ] **Step 6: Run runtime, adapter, and controller tests**

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/AudioRouteRuntimeTests \
  -only-testing:ToolBoxTests/SwiftAudioRouteEngineAdapterTests \
  -only-testing:ToolBoxTests/AudioRoutingServiceTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS. Production still uses the existing native controller until Task 7.

- [ ] **Step 7: Commit the unwired Swift control module**

```bash
git add Sources/ToolBox/AudioRouting/CoreAudioHAL.swift \
  Sources/ToolBox/AudioRouting/AudioRouteRuntime.swift \
  Sources/ToolBox/AudioRouting/SwiftAudioRouteEngineAdapter.swift \
  Sources/ToolBox/AudioRouting/AudioRouteController.swift \
  Tests/ToolBoxTests/AudioRouteRuntimeTests.swift \
  Tests/ToolBoxTests/SwiftAudioRouteEngineAdapterTests.swift
git commit -m "refactor(audio): add Swift route runtime"
```

**Gate 4:** Scripted HAL tests prove complete-intent idempotency, HAL-fingerprint rebuild, candidate rollback, and typed cleanup failure without changing production behavior.

---

### Task 5: Swift HAL Observation and Resource Transactions

**Files:**
- Modify: `Sources/ToolBox/AudioRouting/CoreAudioHAL.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteRuntime.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteEngine.h`
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteEngine.mm`
- Create: `Tests/ToolBoxTests/CoreAudioHALTests.swift`
- Modify: `Tests/ToolBoxTests/AudioRouteRuntimeTests.swift`

**Interfaces:**
- Consumes: private HAL port and C++ kernel ref from Tasks 3-4.
- Produces: `SystemCoreAudioHAL`, callback-bridge C functions, complete HAL fingerprints, listener receipts, and ordered resource teardown receipts.

- [ ] **Step 1: Write failing observation tests with injected property reads**

```swift
func testObservationIncludesProcessTapAggregateAndOutputFormats() throws {
    let properties = FixtureHALProperties.processOnDeviceAWithTap441AndOutput48
    let hal = SystemCoreAudioHAL(propertyAccess: properties)

    let snapshot = try hal.observe(
        HALObservationRequest(intent: AudioRouteTestFixtures.intent())
    )
    let route = try XCTUnwrap(snapshot.routesByID["output-A"])

    XCTAssertEqual(route.processDeviceIDsByObjectID[42], [100])
    XCTAssertEqual(route.tapFormatsByProcessObjectID[42]?.sampleRate, 44_100)
    XCTAssertEqual(route.aggregateFormatsByProcessObjectID[42]?.sampleRate, 44_100)
    XCTAssertEqual(route.outputFormat.sampleRate, 48_000)
}

func testPropertyChangeOnlyPublishesFactEvent() async throws {
    let properties = FixtureHALProperties.processOnDeviceAWithTap441AndOutput48
    let hal = SystemCoreAudioHAL(propertyAccess: properties)
    let changes = hal.changes(for: [.processDevices(42), .tapFormat(77)])
    properties.emit(selector: kAudioProcessPropertyDevices, objectID: 42)

    XCTAssertEqual(await changes.firstValue(), .propertyChanged)
    XCTAssertEqual(properties.mutationCallCount, 0)
}
```

`FixtureHALProperties` is the `CoreAudioPropertyAccess` test adapter in this test file. It returns fixed object IDs/ASBDs, stores registered listener closures, and increments `mutationCallCount` for every resource mutation; `emit(selector:objectID:)` invokes only matching stored listeners.

- [ ] **Step 2: Run CoreAudio HAL tests and verify they fail**

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/CoreAudioHALTests CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Move query helpers from Objective-C++ to Swift**

Implement typed reads for device-by-UID, default output, process output devices, device streams, stream virtual format, Tap format, alive state, nominal rate, buffer frame size, latency, and safety offset. Use `CoreAudioPropertyReader` where its existing interface fits; add scoped read helpers locally rather than string parsing.

Inject the low-level calls through this test seam:

```swift
protocol CoreAudioPropertyAccess: AnyObject {
    func dataSize(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> UInt32
    func readData(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        into buffer: UnsafeMutableRawBufferPointer
    ) throws
    func addListener(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        handler: @escaping @Sendable () -> Void
    ) throws -> HALListenerReceipt
}
```

`HALListenerReceipt.cancel()` removes exactly the registered object/address/block tuple and is called during realization retirement.

- [ ] **Step 4: Register the exact property listeners**

Install listeners for:

```swift
HALObservation.processDevices(processObjectID)
HALObservation.tapFormat(tapID)
HALObservation.aggregateInputStreams(aggregateID)
HALObservation.aggregateInputFormat(streamID)
HALObservation.outputAlive(deviceID)
HALObservation.outputStreams(deviceID)
HALObservation.outputNominalRate(deviceID)
HALObservation.outputStreamFormat(streamID)
HALObservation.audioServerGeneration
```

Listener callbacks enqueue/coalesce facts and never mutate realization state directly.

- [ ] **Step 5: Expose minimal callback-bridge functions**

```c
OSStatus TBAudioCreateCaptureIOProc(
    AudioObjectID deviceID,
    TBAudioRealtimeKernelRef kernel,
    uint64_t generation,
    uint32_t sourceIndex,
    AudioDeviceIOProcID* outIOProcID,
    TBAudioCallbackLeaseRef* outLease
);
OSStatus TBAudioCreateOutputIOProc(
    AudioObjectID deviceID,
    TBAudioRealtimeKernelRef kernel,
    uint64_t generation,
    AudioDeviceIOProcID* outIOProcID,
    TBAudioCallbackLeaseRef* outLease
);
void TBAudioDetachIOProcLease(TBAudioCallbackLeaseRef lease);
uint64_t TBAudioIOProcLeaseInFlight(TBAudioCallbackLeaseRef lease);
```

Swift owns the returned IDs and receipts; Objective-C++ owns only trampoline context memory until lease retirement.

- [ ] **Step 6: Implement ordered HAL transaction receipts**

Prepare resources in this order: resolve output, create kernel, create Tap, create Aggregate, verify actual Tap/Aggregate/output ASBD, create IOProcs. Start output/capture according to the transaction mode. Roll back in exact reverse acquisition order and report every failed cleanup resource.

- [ ] **Step 7: Run HAL, runtime, lifecycle, and registry tests**

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/CoreAudioHALTests \
  -only-testing:ToolBoxTests/AudioRouteRuntimeTests \
  -only-testing:ToolBoxTests/AudioRouteLifecycleTests \
  -only-testing:ToolBoxTests/AudioRegistryProjectionTests CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 8: Commit the Swift HAL adapter**

```bash
git add Sources/ToolBox/AudioRouting/CoreAudioHAL.swift \
  Sources/ToolBox/AudioRouting/AudioRouteRuntime.swift \
  Sources/ToolBox/AudioRouting/AudioRouteEngine.h \
  Sources/ToolBox/AudioRouting/AudioRouteEngine.mm \
  Tests/ToolBoxTests/CoreAudioHALTests.swift \
  Tests/ToolBoxTests/AudioRouteRuntimeTests.swift
git commit -m "refactor(audio): move HAL lifecycle into Swift"
```

**Gate 5:** Swift owns all HAL IDs and listener receipts, observation fingerprints include every runtime format source, and cleanup errors retain exact stage/status/resource data.

---

### Task 6: Immutable Format Contracts and Prewarmed SRC

**Files:**
- Create: `Sources/ToolBox/AudioRouting/AudioFormatContract.swift`
- Create: `Sources/ToolBox/AudioRouting/AudioRouteSampleRateConverter.hpp`
- Create: `Sources/ToolBox/AudioRouting/AudioRouteSampleRateConverter.cpp`
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteRealtimeKernel.hpp`
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteRealtimeKernel.cpp`
- Modify: `project.yml`
- Create: `Tests/ToolBoxTests/AudioFormatContractTests.swift`
- Create: `Tests/ToolBoxTests/AudioRouteSampleRateConverterTests.swift`

**Interfaces:**
- Consumes: observed source/output ASBD fingerprints and realtime buffer views.
- Produces: immutable `AudioFormatContract`, canonical non-interleaved Float32 stereo at output rate, prewarmed source converters, channel mapping, and output conversion.

- [ ] **Step 1: Write failing table-driven format negotiation tests**

```swift
func testSupportedFormatMatrix() throws {
    for fixture in [
        FormatFixture.mono441Interleaved,
        .stereo441Interleaved,
        .stereo48NonInterleaved,
        .stereo96Interleaved
    ] {
        let contract = try AudioFormatContract.negotiate(
            source: fixture.asbd,
            output: FormatFixture.stereo48NonInterleaved.asbd
        )
        XCTAssertEqual(contract.canonical.channelCount, 2)
        XCTAssertEqual(contract.canonical.sampleRate, 48_000)
    }
}

func testUnknownIntegerLayoutFailsClosed() {
    XCTAssertThrowsError(
        try AudioFormatContract.negotiate(
            source: FormatFixture.unsupportedVariablePacket.asbd,
            output: FormatFixture.stereo48NonInterleaved.asbd
        )
    )
}
```

Implement `FormatFixture` in `AudioFormatContractTests.swift` with a single ASBD builder. `mono441Interleaved` is packed Float32 with one channel and four bytes/frame; stereo interleaved fixtures use two channels and eight bytes/frame; stereo non-interleaved fixtures add `kAudioFormatFlagIsNonInterleaved` and use four bytes/frame per buffer. `unsupportedVariablePacket` uses `mFramesPerPacket == 0` and must be rejected.

- [ ] **Step 2: Add failing SRC quality tests**

Generate deterministic silence, impulse, 997 Hz sine, logarithmic sweep, and full-scale boundary fixtures. For 44.1->48, 48->44.1, 48->96, and 96->48, assert:

```swift
XCTAssertGreaterThanOrEqual(metrics.snrDB, 90)
XCTAssertLessThanOrEqual(metrics.thdNDB, -90)
XCTAssertLessThanOrEqual(metrics.passbandRippleDB, 0.1)
XCTAssertLessThanOrEqual(metrics.aliasDBFS, -80)
```

- [ ] **Step 3: Run format/SRC tests and verify missing implementation**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/AudioFormatContractTests \
  -only-testing:ToolBoxTests/AudioRouteSampleRateConverterTests CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 4: Implement pure Swift format negotiation**

```swift
struct AudioFormatContract: Equatable, Sendable {
    let source: AudioFormatFingerprint
    let canonical: CanonicalAudioFormat
    let output: AudioFormatFingerprint
    let sourceChannelMap: AudioChannelMap
    let outputChannelMap: AudioChannelMap
    let requiresSampleRateConversion: Bool

    static func negotiate(
        source: AudioStreamBasicDescription,
        output: AudioStreamBasicDescription
    ) throws -> AudioFormatContract
}
```

Support packed Float32 mono/stereo in interleaved or non-interleaved layouts. Mono duplicates to L/R. Multichannel requires an explicit matrix; otherwise return `.unsupportedFormat`. Variable-packet and unknown sample types fail closed.

- [ ] **Step 5: Add AudioToolbox and implement the converter adapter**

Add `AudioToolbox.framework` to the application target in `project.yml`. Create, configure, prime, and allocate `AudioConverterRef` plus all scratch buffers on the control thread. Equal-rate paths bypass the converter. Realtime calls only use preallocated views and never create/reset/set properties.

```cpp
class TBAudioSampleRateConverter final {
public:
    static std::unique_ptr<TBAudioSampleRateConverter> Create(
        const TBAudioRealtimeFormat& source,
        const TBAudioRealtimeFormat& destination,
        uint32_t maximumInputFrames,
        uint32_t maximumOutputFrames
    );
    bool Convert(
        const TBAudioRealtimeInputView& input,
        TBAudioRealtimeOutputView& output
    ) noexcept;
};
```

- [ ] **Step 6: Integrate source/output adapters into the kernel**

Capture converts actual source format to canonical before the ring. Output mixes canonical source rings, applies ramps, then converts canonical to the actual output view. A view that differs from the immutable contract outputs zero and increments format fatal.

- [ ] **Step 7: Run quality, realtime, and sanitizer tests**

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/AudioFormatContractTests \
  -only-testing:ToolBoxTests/AudioRouteSampleRateConverterTests \
  -only-testing:ToolBoxTests/AudioRouteRealtimeTests CODE_SIGNING_ALLOWED=NO

xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -enableAddressSanitizer YES \
  -only-testing:ToolBoxTests/AudioRouteSampleRateConverterTests \
  -only-testing:ToolBoxTests/AudioRouteRealtimeTests CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 8: Profile the steady-state converter before wiring production**

Run the deterministic converter harness under Instruments Allocations and Time Profiler for ten minutes after a one-second warmup. Acceptance: zero steady-state allocations from `pushCapture`/`renderOutput`, no lock wait on callback threads, and callback p99 below 25% of the hardware period. If any criterion fails, keep cross-rate routes fail-closed and do not proceed to Task 7 until the converter implementation passes.

- [ ] **Step 9: Commit the format defense**

```bash
git add project.yml Sources/ToolBox/AudioRouting/AudioFormatContract.swift \
  Sources/ToolBox/AudioRouting/AudioRouteSampleRateConverter.* \
  Sources/ToolBox/AudioRouting/AudioRouteRealtimeKernel.* \
  Tests/ToolBoxTests/AudioFormatContractTests.swift \
  Tests/ToolBoxTests/AudioRouteSampleRateConverterTests.swift
git commit -m "feat(audio): add immutable format conversion contracts"
```

**Gate 6:** Supported 44.1/48/96 kHz mono/stereo layouts meet objective quality and realtime constraints; unsupported layouts fail before Tap muting begins.

---

### Task 7: Transactional Source Rebuild and Production Cutover

**Files:**
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteRuntime.swift`
- Modify: `Sources/ToolBox/AudioRouting/CoreAudioHAL.swift`
- Modify: `Sources/ToolBox/AudioRouting/SwiftAudioRouteEngineAdapter.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioRoutingService.swift`
- Modify: `Tests/ToolBoxTests/AudioRouteRuntimeTests.swift`
- Modify: `Tests/ToolBoxTests/SwiftAudioRouteEngineAdapterTests.swift`
- Modify: `Tests/ToolBoxTests/AudioRoutingServiceTests.swift`

**Interfaces:**
- Consumes: System HAL transactions, immutable contracts, and realtime kernel from Tasks 3-6.
- Produces: source-level candidate prepare/preroll/commit/rollback/retirement, make-before-break capability decision, and production engine wiring.

- [ ] **Step 1: Write failing ordered-transaction tests**

```swift
func testMakeBeforeBreakCommitsCandidateBeforeRetiringOldSource() throws {
    let hal = ScriptedCoreAudioHAL(
        observation: AudioRouteTestFixtures.observation(tapSampleRate: 44_100),
        capabilities: [.parallelCapture]
    )
    let runtime = AudioRouteRuntime(hal: hal)
    let intent = AudioRouteTestFixtures.intent()
    _ = try runtime.converge(to: intent)
    hal.operationLog.removeAll()
    hal.observation = AudioRouteTestFixtures.observation(tapSampleRate: 48_000)

    _ = try runtime.converge(to: intent)

    XCTAssertEqual(hal.operationLog, [
        .muteOld(42), .prepareCandidate(42), .startCandidateCapture(42),
        .prerollCandidate(42), .commitCandidate(42), .fadeInCandidate(42),
        .detachOld(42), .drainOldCallbacks(42), .destroyOld(42)
    ])
}

func testBreakBeforeMakeNeverRendersOldFormatAfterMute() throws {
    let hal = ScriptedCoreAudioHAL(
        observation: AudioRouteTestFixtures.observation(tapSampleRate: 44_100),
        capabilities: []
    )
    let runtime = AudioRouteRuntime(hal: hal)
    let intent = AudioRouteTestFixtures.intent()
    _ = try runtime.converge(to: intent)
    hal.operationLog.removeAll()
    hal.observation = AudioRouteTestFixtures.observation(tapSampleRate: 48_000)

    _ = try runtime.converge(to: intent)

    XCTAssertEqual(hal.operationLog.prefix(3), [
        .fadeOldToZero(42), .detachOld(42), .stopOldCapture(42)
    ])
}

func testSourceFailureDoesNotStopSibling() throws {
    let hal = ScriptedCoreAudioHAL(
        observation: twoSourceObservation(tapSampleRateFor42: 44_100)
    )
    let runtime = AudioRouteRuntime(hal: hal)
    let intent = twoSourceIntent()
    _ = try runtime.converge(to: intent)
    hal.failNext(sourceID: 42, stage: .startCapture)
    hal.observation = twoSourceObservation(tapSampleRateFor42: 48_000)

    XCTAssertThrowsError(try runtime.converge(to: intent))
    XCTAssertTrue(hal.activeSourceIDs.contains(43))
    XCTAssertFalse(hal.operationLog.contains(.destroyOld(43)))
}
```

Define `twoSourceIntent()` by adding process object ID `43` to the same output plan, and define `twoSourceObservation(tapSampleRateFor42:)` with both process-device/Tap/Aggregate entries. These helpers belong in `AudioRouteRuntimeTests.swift`; all IDs and formats reuse `AudioRouteTestFixtures` constants.

- [ ] **Step 2: Run runtime/adapter/service tests and verify failure**

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/AudioRouteRuntimeTests \
  -only-testing:ToolBoxTests/SwiftAudioRouteEngineAdapterTests \
  -only-testing:ToolBoxTests/AudioRoutingServiceTests CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement the source realization state machine**

```swift
enum AudioSourceRealizationState: Equatable, Sendable {
    case preparing, prerolling, active, muting, rebuilding
    case rollback, failClosed, detached, drainingCallbacks, retired
}
```

Preroll uses two output periods bounded to `256...2048` frames. Muting/fade-in uses 10 ms at canonical sample rate. Commit swaps generation/kernel ownership before any old resource is destroyed.

- [ ] **Step 4: Implement both transaction modes**

Use make-before-break only when the HAL adapter confirms candidate and old capture can coexist. Otherwise perform 10 ms fade-to-zero, detach/stop old capture, prepare/preroll candidate, and 10 ms fade-in. Short silence is acceptable; rendering old-format PCM is not.

- [ ] **Step 5: Wire production to the Swift adapter**

Change only the engine construction in `AudioRoutingService`:

```swift
engine = AudioRouteController(
    nativeEngine: SwiftAudioRouteEngineAdapter(
        runtime: AudioRouteRuntime(hal: SystemCoreAudioHAL())
    )
)
```

Do not change `AudioRouteEngineControlling`, persisted rules, or UI calls.

- [ ] **Step 6: Add the dynamic-change regression**

Drive an unchanged `AudioRoutePlan` through Tap ASBD 44.1->48->44.1 and process device A->B observations. Assert three realization generations, sibling continuity, no stale generation render, and final active state without user source toggling.

- [ ] **Step 7: Run focused control/lifecycle tests**

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/AudioRouteRuntimeTests \
  -only-testing:ToolBoxTests/SwiftAudioRouteEngineAdapterTests \
  -only-testing:ToolBoxTests/AudioRoutingServiceTests \
  -only-testing:ToolBoxTests/AudioRouteLifecycleTests CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 8: Commit the production cutover**

```bash
git add Sources/ToolBox/AudioRouting/AudioRouteRuntime.swift \
  Sources/ToolBox/AudioRouting/CoreAudioHAL.swift \
  Sources/ToolBox/AudioRouting/SwiftAudioRouteEngineAdapter.swift \
  Sources/ToolBox/AudioRouting/AudioRoutingService.swift \
  Tests/ToolBoxTests/AudioRouteRuntimeTests.swift \
  Tests/ToolBoxTests/SwiftAudioRouteEngineAdapterTests.swift \
  Tests/ToolBoxTests/AudioRoutingServiceTests.swift
git commit -m "refactor(audio): cut over to transactional Swift runtime"
```

**Gate 7:** Unchanged user plans rebuild on observed HAL changes, candidate failure cannot permanently mute the application, and one source rebuild leaves siblings active.

---

### Task 8: Automatic Health Recovery and Diagnostics

**Files:**
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteRuntime.swift`
- Modify: `Sources/ToolBox/AudioRouting/SwiftAudioRouteEngineAdapter.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioRoutingModels.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioRoutingService.swift`
- Modify: `Tests/ToolBoxTests/AudioRouteHealthEvaluatorTests.swift`
- Modify: `Tests/ToolBoxTests/AudioRouteRecoveryPolicyTests.swift`
- Modify: `Tests/ToolBoxTests/AudioRouteRuntimeTests.swift`
- Modify: `Tests/ToolBoxTests/AudioRouteDiagnosticsTests.swift`

**Interfaces:**
- Consumes: atomic kernel snapshots, HAL change facts, pure health/recovery policies, and existing watchdog maintenance cadence.
- Produces: automatic source-local recovery, exhausted-budget fail-closed behavior, and privacy-safe structured diagnostics.

- [ ] **Step 1: Add failing end-to-end recovery tests with a manual clock**

```swift
func testActiveCallbacksWithCorruptPCMTriggerRecovery() throws {
    let clock = ManualAudioRouteClock()
    let hal = ScriptedCoreAudioHAL(observation: AudioRouteTestFixtures.observation())
    let runtime = AudioRouteRuntime(hal: hal, clock: clock)
    let adapter = SwiftAudioRouteEngineAdapter(runtime: runtime)
    _ = try runtime.converge(to: AudioRouteTestFixtures.intent())
    hal.setHealthSample(
        42,
        AudioRouteTestFixtures.healthSample(
            outputFrameCount: 512,
            formatMismatchCount: 1
        )
    )

    _ = adapter.performMaintenance()

    XCTAssertEqual(adapter.diagnostics().first?.health, .rebuild(.formatContractViolation))
}

func testRetryBudgetExhaustionReleasesTapAndFailsClosed() throws {
    let clock = ManualAudioRouteClock()
    let hal = ScriptedCoreAudioHAL(observation: AudioRouteTestFixtures.observation())
    let runtime = AudioRouteRuntime(hal: hal, clock: clock)
    let adapter = SwiftAudioRouteEngineAdapter(runtime: runtime)
    _ = try runtime.converge(to: AudioRouteTestFixtures.intent())
    hal.failEveryTransaction(sourceID: 42, stage: .startCapture)
    hal.setHealthSample(
        42,
        AudioRouteTestFixtures.healthSample(formatMismatchCount: 1)
    )
    for delay in [Duration.milliseconds(250), .seconds(1), .seconds(4)] {
        _ = adapter.performMaintenance()
        clock.advance(by: delay)
    }

    XCTAssertEqual(adapter.diagnostics().first?.runtimeState, .failClosed)
    XCTAssertTrue(hal.operationLog.contains(.destroyTap(42)))
}

func testNewHALFingerprintResetsExhaustedBudget() throws {
    let (_, hal, _, adapter) = exhaustedRuntimeFixture()
    hal.observation = AudioRouteTestFixtures.observation(server: 2)

    _ = adapter.performMaintenance()

    XCTAssertEqual(adapter.diagnostics().first?.recoveryAttempt, 1)
}
```

Use this test clock:

```swift
final class ManualAudioRouteClock: AudioRouteClock {
    private(set) var now = AudioRouteMonotonicTime(uptimeNanoseconds: 0)

    func advance(by duration: Duration) {
        let seconds = duration.components.seconds
        let attoseconds = duration.components.attoseconds
        let delta = UInt64(seconds) * 1_000_000_000
            + UInt64(attoseconds / 1_000_000_000)
        now = AudioRouteMonotonicTime(uptimeNanoseconds: now.uptimeNanoseconds + delta)
    }
}
```

`exhaustedRuntimeFixture()` performs the three scripted failed attempts before returning its clock, HAL, runtime, and adapter; it asserts the precondition `runtimeState == .failClosed` before the fingerprint change.

- [ ] **Step 2: Run health/runtime/diagnostics tests and verify failure**

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/AudioRouteHealthEvaluatorTests \
  -only-testing:ToolBoxTests/AudioRouteRecoveryPolicyTests \
  -only-testing:ToolBoxTests/AudioRouteRuntimeTests \
  -only-testing:ToolBoxTests/AudioRouteDiagnosticsTests CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Drain HAL changes and kernel deltas in maintenance**

At each existing 250 ms maintenance tick, coalesce HAL facts, observe a fresh fingerprint, snapshot kernel counters, evaluate wrapping deltas, and request only the smallest affected source/route converge operation.

- [ ] **Step 4: Implement bounded retry and fail-closed release**

Use delays `[250 ms, 1 s, 4 s]`, at most three automatic attempts in 30 seconds. On exhaustion, mute and detach the failed source, stop/destroy IOProc and Aggregate, destroy Tap, and retain a typed exhausted-budget diagnostic. Only a new intent, HAL fingerprint, or server generation resets it.

- [ ] **Step 5: Extend diagnostics without changing UI behavior**

Add optional/defaulted fields to `AudioRouteDiagnosticsSnapshot`:

```swift
let health: AudioRouteHealthDecision?
let runtimeState: AudioSourceRealizationState?
let runtimeStage: HALStage?
let expectedFormat: AudioFormatFingerprint?
let observedFormat: AudioFormatFingerprint?
let recoveryAttempt: Int
let lastOSStatus: OSStatus?
let rollbackSucceeded: Bool?
```

Existing callers continue to compile through initializer defaults. Do not expose raw process names, PIDs, or captured samples.

- [ ] **Step 6: Run focused recovery and service tests**

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/AudioRouteHealthEvaluatorTests \
  -only-testing:ToolBoxTests/AudioRouteRecoveryPolicyTests \
  -only-testing:ToolBoxTests/AudioRouteRuntimeTests \
  -only-testing:ToolBoxTests/AudioRouteDiagnosticsTests \
  -only-testing:ToolBoxTests/AudioRoutingServiceTests CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 7: Commit automatic recovery**

```bash
git add Sources/ToolBox/AudioRouting/AudioRouteRuntime.swift \
  Sources/ToolBox/AudioRouting/SwiftAudioRouteEngineAdapter.swift \
  Sources/ToolBox/AudioRouting/AudioRoutingModels.swift \
  Sources/ToolBox/AudioRouting/AudioRoutingService.swift \
  Tests/ToolBoxTests/AudioRouteHealthEvaluatorTests.swift \
  Tests/ToolBoxTests/AudioRouteRecoveryPolicyTests.swift \
  Tests/ToolBoxTests/AudioRouteRuntimeTests.swift \
  Tests/ToolBoxTests/AudioRouteDiagnosticsTests.swift
git commit -m "feat(audio): recover degraded routes from quality signals"
```

**Gate 8:** A route whose callbacks still advance but whose PCM is invalid is detected and recovered; legal silence, one underrun, and clipping do not cause rebuild storms.

---

### Task 9: Remove Legacy Lifecycle Ownership

**Files:**
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteEngine.h`
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteEngine.mm`
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteController.swift`
- Modify: `Sources/ToolBox/DisplayControl/Darwin/DisplayControlBridgingHeader.h`
- Delete when no longer referenced: `Sources/ToolBox/AudioRouting/AudioRouteDSP.cpp`
- Delete when no longer referenced: `Sources/ToolBox/AudioRouting/AudioRouteDSP.hpp`
- Delete when no longer referenced: `Sources/ToolBox/AudioRouting/AudioRouteFormat.cpp`
- Delete when no longer referenced: `Sources/ToolBox/AudioRouting/AudioRouteFormat.hpp`
- Modify: `Tests/ToolBoxTests/AudioRouteLifecycleTests.swift`
- Modify: `Tests/ToolBoxTests/AudioRouteDSPTests.swift`

**Interfaces:**
- Consumes: production Swift runtime and C callback/kernel seams.
- Produces: an Objective-C++ file containing no route collection, resource lifecycle, quarantine, or recovery ownership.

- [ ] **Step 1: Add a source-level architecture guard**

Create a test/script assertion that `AudioRouteEngine.mm` contains `CaptureIOProc` and `OutputIOProc` but no `@interface TBAudioRouteEngine`, `NSMutableDictionary`, `quarantinedRoutes`, `retiredRoutes`, `AudioHardwareCreateProcessTap`, or `AudioHardwareCreateAggregateDevice`.

- [ ] **Step 2: Run the guard and verify it fails against the legacy file**

```bash
rg -n "@interface TBAudioRouteEngine|quarantinedRoutes|retiredRoutes|AudioHardwareCreate(ProcessTap|AggregateDevice)" \
  Sources/ToolBox/AudioRouting/AudioRouteEngine.mm
```

Expected: matches exist before cleanup.

- [ ] **Step 3: Delete legacy native controller and lifecycle implementation**

Remove `NativeAudioRouteEngineController`, `TBAudioRouteEngine`, `SourceContext`, `RouteContext`, native route dictionaries, quarantine/retirement arrays, and duplicate HAL query/validation helpers. Keep only callback view validation, callback lease handling, and bridge functions declared in the C header.

- [ ] **Step 4: Collapse obsolete DSP/format helpers**

Move any still-used pure gain/format operations into the realtime kernel or Swift format contract. Delete `AudioRouteDSP.*` and `AudioRouteFormat.*` only after `rg` proves no production or test references remain. Rewrite the remaining tests through `TBAudioRealtimeKernelRef` rather than preserving obsolete test-only interfaces.

- [ ] **Step 5: Run focused lifecycle and realtime tests**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/AudioRouteLifecycleTests \
  -only-testing:ToolBoxTests/AudioRouteRealtimeTests \
  -only-testing:ToolBoxTests/AudioRouteDSPTests \
  -only-testing:ToolBoxTests/AudioRouteRuntimeTests CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 6: Re-run the architecture guard**

```bash
test -z "$(rg -n '@interface TBAudioRouteEngine|quarantinedRoutes|retiredRoutes|AudioHardwareCreate(ProcessTap|AggregateDevice)' \
  Sources/ToolBox/AudioRouting/AudioRouteEngine.mm)"
```

Expected: exit 0 with no output.

- [ ] **Step 7: Commit legacy removal**

```bash
git add -A Sources/ToolBox/AudioRouting Sources/ToolBox/DisplayControl/Darwin/DisplayControlBridgingHeader.h \
  Tests/ToolBoxTests/AudioRouteLifecycleTests.swift Tests/ToolBoxTests/AudioRouteDSPTests.swift
git commit -m "refactor(audio): remove Objective-C++ lifecycle engine"
```

**Gate 9:** `.mm` is only a callback bridge, Swift is the sole lifecycle owner, and no obsolete dual path remains.

---

### Task 10: Full Verification and Hardware Acceptance

**Files:**
- Modify: `scripts/verify-audio-routing-build.sh`
- Modify: `docs/testing/per-app-audio-acceptance.md`
- Modify: `docs/superpowers/specs/2026-07-29-audio-engine-runtime-resilience-design.md` only if measured results require a threshold change
- Test: all `Tests/ToolBoxTests/AudioRoute*Tests.swift`

**Interfaces:**
- Consumes: completed Swift runtime, HAL adapter, callback bridge, and realtime kernel.
- Produces: repeatable CI verification plus recorded hardware evidence; no product interface change.

- [ ] **Step 1: Add deterministic long-run tests to the verification script**

Add focused invocations for runtime, format, SRC, realtime, lifecycle, ASan, and TSan suites before Debug/Release builds. Use explicit `CODE_SIGNING_ALLOWED=NO` for tests and a dedicated `/tmp/mactoolbox-audio-verification` derived data path.

- [ ] **Step 2: Add the acceptance rows**

Record columns for machine, macOS version, app/version, source transition, output device/transport, before/after ASBD fingerprints, recovery time, underrun/overrun/resync deltas, CPU p95, latency p95, and result.

Required rows:

```text
44.1 -> 48 -> 96 -> 44.1 kHz
mono -> stereo -> mono
interleaved -> non-interleaved
main process -> helper -> main process
process output device A -> B
built-in, USB, HDMI, Bluetooth profile change
device unplug/replug
sleep/wake
coreaudiod restart
8-hour continuous playback
```

- [ ] **Step 3: Run the full automated verification**

```bash
./scripts/verify-audio-routing-build.sh
```

Expected: full XCTest suite, Debug build, Release build, codesign verification, plist lint, CoreAudio linkage, and `git diff --check` all pass.

- [ ] **Step 4: Run explicit sanitizer suites**

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -enableAddressSanitizer YES \
  -only-testing:ToolBoxTests/AudioRouteLifecycleTests \
  -only-testing:ToolBoxTests/AudioRouteRealtimeTests \
  -only-testing:ToolBoxTests/AudioRouteSampleRateConverterTests CODE_SIGNING_ALLOWED=NO

xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -enableThreadSanitizer YES \
  -only-testing:ToolBoxTests/AudioRouteLifecycleTests \
  -only-testing:ToolBoxTests/AudioRouteRealtimeTests CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Run realtime allocation/performance profiling**

After one-second warmup, profile ten minutes per supported source/output conversion. Acceptance: zero steady-state callback allocations, no callback lock waits, callback p99 below 25% of device period, single-route CPU p95 <=5%, four-route CPU p95 <=15%, and built-in/USB 48 kHz added latency p95 <=50 ms.

- [ ] **Step 6: Run the real-app switching reproduction**

Use the application that previously produced electrical noise. Switch among its known audio sources repeatedly while recording fingerprints and counter deltas. Acceptance: no sustained noise, no manual repeated switching required for recovery, and any format/topology change reaches active new generation within one second or explicitly fails closed.

- [ ] **Step 7: Run resource and endurance checks**

Complete 100 physical device switches, 1,000 synthetic rebuilds, and eight hours continuous playback. Acceptance: resource counts return to baseline, no monotonic memory growth, no sustained underrun, and no retry storm.

- [ ] **Step 8: Update design only from evidence**

If measured hardware evidence requires threshold changes, edit the design and acceptance docs in the same commit with the measurement rows. Do not weaken callback safety, fail-closed behavior, or SRC quality gates to make a row pass.

- [ ] **Step 9: Commit verification evidence**

```bash
git add scripts/verify-audio-routing-build.sh docs/testing/per-app-audio-acceptance.md \
  docs/superpowers/specs/2026-07-29-audio-engine-runtime-resilience-design.md
git commit -m "test(audio): verify runtime resilience across format changes"
```

**Gate 10:** Automated, sanitizer, allocation, objective quality, real-app switching, hardware matrix, and endurance evidence all pass. Any unrun hardware row remains an explicit release blocker rather than an assumed success.
