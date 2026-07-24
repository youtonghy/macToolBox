# Audio Control-Plane Integrity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the three control-plane state races that can recreate routes during quit, forget a successfully rolled-back route, or restore a stale gain after an unrelated route fails.

**Architecture:** Keep `AudioRoutingService` as the `@MainActor` UI facade and `AudioRouteController` as the actor-owned native lifecycle module. Treat `AudioRouteApplyReport.plans` as the effective engine state, invalidate the service session before awaiting shutdown, and keep the watchdog's immutable plan snapshot synchronized after runtime parameter changes.

**Tech Stack:** Swift 5, Combine, Swift concurrency, XCTest, XcodeGen, Core Audio adapter fakes.

## Global Constraints

- Preserve the current macOS 14.0 deployment target and macOS 14.2 Process Tap availability gate.
- Do not change the public UI workflow, persisted rule schema, native Core Audio interface, or realtime callback code.
- Keep unsupported or uncertain native states fail-closed; never silently reinstall a route after shutdown begins.
- Follow TDD for every task: add one failing behavioral test, run it to confirm the expected failure, then apply the smallest production change.
- Preserve every pre-existing dirty-worktree change. Do not stage or commit files in this plan.
- Run implementation tasks serially because they overlap `AudioRoutingService.swift` and its test harness.

---

### Task 1: Quiesce the service before awaiting route shutdown

**Files:**
- Modify: `Tests/ToolBoxTests/AudioRoutingServiceTests.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioRoutingService.swift:695`

**Interfaces:**
- Consumes: existing synchronous `AudioRoutingService.stop()` quiesce behavior.
- Produces: `shutdown()` invalidates the current session and owns exactly one `.serviceStopped` engine drain.

- [x] **Step 1: Add the blocked-stop regression test**

Add `testShutdownInvalidatesSessionBeforeAwaitingEngineStop`. Start a service, block the fake engine's next stop, begin `shutdown()`, wait until the stop is observed, explicitly submit a reconcile while the stop is suspended, release the stop, and submit another late reconcile. Assert that the engine saw one reconcile total, one `.serviceStopped` reason, and no effective plans after shutdown.

Extend `WatchdogAudioRouteEngine` with a stop waiter that mirrors its existing reconcile waiter:

```swift
private var stopWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

func waitUntilStopCount(_ count: Int) async {
    guard recordedStopReasons.count < count else { return }
    await withCheckedContinuation { continuation in
        stopWaiters.append((count, continuation))
    }
}
```

Resume matching waiters immediately after appending the stop reason.

- [x] **Step 2: Verify the test is red**

Run:

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' -only-testing:ToolBoxTests/AudioRoutingServiceTests/testShutdownInvalidatesSessionBeforeAwaitingEngineStop CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because the explicit reconcile reaches the engine while the current `shutdown()` is suspended in `stopAll`.

- [x] **Step 3: Reuse the established quiesce path**

Make `shutdown()` call `stop()` before its first suspension point, await the single `shutdownTask` created by `stop()`, clear that task after it completes, and return its report. Do not invoke `engine.stopAll` through a second fallback path.

- [x] **Step 4: Verify focused lifecycle behavior**

Run the new test plus `testFastRestartWaitsForPreviousStopBeforeReconcilingAgain` and `testStoppedServiceRejectsLateReconcile`. Expected: PASS with one engine stop for the shutdown path.

---

### Task 2: Preserve effective engine plans after a rolled-back topology change

**Files:**
- Modify: `Tests/ToolBoxTests/AudioRoutingServiceTests.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioRoutingService.swift:451`

**Interfaces:**
- Consumes: `AudioRouteController.reconcile` already returns the old effective plans when native rollback succeeds.
- Produces: service-side `appliedPlans` and watchdog input always derive from `AudioRouteApplyReport.plans`, including `.failed` reports.

- [x] **Step 1: Add a service-level rollback test**

Add `testRolledBackTopologyRemainsAvailableForRuntimeGainUpdate`. Configure `WatchdogAudioRouteEngine` to fail one topology reconcile while returning its current plans. Change the process object ID to trigger that failure, then change the volume. Assert that the service sends a runtime update for the old effective process object rather than issuing another full reconcile.

The fake engine should support a one-shot failure without mutating its stored plans:

```swift
private var nextReconcileFailureMessage: String?

func failNextReconcileKeepingCurrentPlans(message: String) {
    nextReconcileFailureMessage = message
}
```

Its next `reconcile` report must use `.failed(message)` and the pre-existing `plans`.

- [x] **Step 2: Verify the test is red**

Run only the new test. Expected: FAIL because the service currently assigns `appliedPlans = []` for every `.failed` report and therefore falls back to another topology reconcile.

- [x] **Step 3: Adopt the report's effective plans**

In the `.failed` branch, assign `report.plans` to `appliedPlans`. If the report contains effective plans, restart the diagnostics watchdog for those plans using the current generation and current process/device snapshots; otherwise cancel it. Keep the requested compilation resolutions for UI failure text and retain the existing `routeError` wording.

- [x] **Step 4: Verify rollback and stale-generation tests**

Run the new test, `testRecoveredRouteFailureKeepsPreviouslyAppliedRoutes`, and `testLateEngineResultCannotOverwriteNewerServiceGeneration`. Expected: PASS; a failed desired topology cannot erase a successfully restored route or overwrite a newer generation.

---

### Task 3: Keep watchdog plans synchronized with runtime gain

**Files:**
- Modify: `Tests/ToolBoxTests/AudioRoutingServiceTests.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioRoutingService.swift:873`

**Interfaces:**
- Consumes: a successful runtime update report containing the controller's effective plans.
- Produces: later fatal-route removal reconciles the surviving routes with their newest gains.

- [x] **Step 1: Make the fake engine model runtime gain accurately**

Update `WatchdogAudioRouteEngine.update(parameters:)` so a successful update rewrites the matching source gain in its stored plans before returning the report. Preserve its existing one-shot stale behavior.

- [x] **Step 2: Add the unrelated-failure regression test**

Add `testRuntimeGainSurvivesUnrelatedFatalRouteRemoval`. Start the existing two-route harness, change Music from 200% to 250%, mark the headset route fatal while the speakers route remains healthy, run one watchdog tick, and assert that Music still has `linearGain == 2.5` in the engine's remaining speakers plan.

- [x] **Step 3: Verify the test is red**

Run only the new test. Expected: FAIL with Music restored to `2.0`, because the watchdog currently rebuilds from the initial compilation snapshot.

- [x] **Step 4: Synchronize the watchdog snapshot**

After a successful runtime update, replace only `watchdogCompilation.plans` with `report.plans` while preserving its rule resolutions. Do not start a new timer or reset diagnostics counters.

- [x] **Step 5: Verify the audio control-plane slice**

Run:

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' -only-testing:ToolBoxTests/AudioRoutingServiceTests CODE_SIGNING_ALLOWED=NO
git diff --check
```

Expected: all `AudioRoutingServiceTests` pass and `git diff --check` exits 0.

---

### Task 4: Integration quality gate

**Files:**
- Review: `Sources/ToolBox/AudioRouting/AudioRoutingService.swift`
- Review: `Tests/ToolBoxTests/AudioRoutingServiceTests.swift`

- [x] **Step 1: Review the final diff for duplicated state and patch-like branches**

Confirm shutdown has one quiesce path, every apply status consumes the report's effective plans consistently, and no new public interface or generic abstraction was introduced.

- [x] **Step 2: Run the repository audio verification gate**

Run:

```bash
./scripts/verify-audio-routing-build.sh
```

Expected: full XCTest, Debug build, Release build, plist/entitlements checks, Core Audio linkage, strict codesign, and diff check all pass.

- [x] **Step 3: Record residual scope**

Keep realtime 4096-frame handling, nominal-rate policy, route-scoped quarantine, HAL listener health, registry epoch consolidation, SRC, multichannel, limiter, and hardware acceptance in their existing follow-up plans. They are deliberately outside this control-plane integrity slice.

---

### Task 5: Close post-integration watchdog state findings

- [x] **Step 1: Add rollback and cleanup-blocked watchdog regressions**

Verify that diagnostics for a retained old route cannot mark a replacement process active, and that a cleanup-blocked reconcile installs a current-generation watchdog instead of leaving the old timer to wake without work.

- [x] **Step 2: Separate effective route health from requested failure presentation**

Build watchdog resolutions from the effective plans returned by the engine, retain requested failure states as a presentation override, and route `.failed` and `.cleanupBlocked` through one shared state transition.

- [x] **Step 3: Repeat final quality gates**

Run the complete XCTest bundle, warnings-as-errors Release build, x86_64 build, repository Release build, artifact validation, and `git diff --check`.
