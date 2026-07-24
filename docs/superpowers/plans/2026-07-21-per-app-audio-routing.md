# Per-App Audio Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add macOS 14.2+ per-application output volume (0%-300%) and output-device routing using public Core Audio Process Taps.

**Architecture:** Persist bundle-ID rules in Swift, discover HAL process/device objects through focused registries, compile rules into per-output-device route plans, and execute those plans through an Objective-C++ Core Audio engine. SwiftUI observes a main-actor service and never enters the realtime callback.

**Tech Stack:** Swift 5, SwiftUI, AppKit, Combine, Core Audio Process Tap, private Aggregate Audio Devices, Objective-C++, XCTest, XcodeGen.

## Execution Status (2026-07-21)

- [x] Rules, versioned persistence, HAL process/device discovery, route compilation, Process Tap engine, realtime DSP, menu controls, detailed settings, permission metadata, documentation, tests, and Debug/Release packaging are implemented.
- [x] The engine uses one Tap-only capture Aggregate per source plus an independent physical output IOProc, a preallocated SPSC ring, bounded drift correction, final peak limiting, format-change rebuilds, and fail-closed cleanup handling.
- [x] Automated verification covers 84 XCTest cases, strict codesign, bundle metadata, framework linkage, and a no-rule Release launch smoke test.
- [ ] Hardware acceptance remains: grant System Audio Recording permission, route real Zoom/helper audio at 100%/300%, switch to a physical headset, test unplug/profile change, and verify quit recovery over a long call.
- [ ] First release supports only same-sample-rate interleaved Float32 stereo capture/output. Multi-channel and cross-sample-rate conversion remain future work.

## Global Constraints

- Keep the app deployment target at macOS 14.0; guard Process Tap behavior with macOS 14.2 availability.
- Use only public APIs and do not install a HAL driver.
- Persist device UIDs and bundle IDs, never AudioObjectIDs or PIDs.
- `0...300` percent maps to linear `0.0...3.0`; `100%` is native gain.
- Never leave a tapped application muted after route startup/rebuild failure.
- Do not add input-device controls in this feature.
- Realtime code must not allocate, block, log, touch Swift/Combine/UserDefaults, or use Objective-C messaging.

---

### Task 1: Rules, persistence, and route planning

**Files:**
- Create: `Sources/ToolBox/AudioRouting/AudioRoutingModels.swift`
- Create: `Sources/ToolBox/AudioRouting/AudioRuleStore.swift`
- Create: `Sources/ToolBox/AudioRouting/RoutePlanCompiler.swift`
- Test: `Tests/ToolBoxTests/AudioRuleStoreTests.swift`
- Test: `Tests/ToolBoxTests/RoutePlanCompilerTests.swift`

**Interfaces:**
- Produces `AppAudioRule`, `AudioOutputDevice`, `AudioProcessSnapshot`, `AudioRoutePlan`, `AudioRouteState`, `AudioRuleStore`, and `RoutePlanCompiler.compile(rules:processes:devices:defaultOutputUID:)`.

- [ ] Write tests for default `100%`, clamping, versioned persistence, corrupt data, default-device resolution, and the rule condition that creates a route.
- [ ] Run focused tests and confirm missing-type failures.
- [ ] Implement the minimal Codable models, store, and pure compiler.
- [ ] Run focused tests and confirm zero failures.

### Task 2: HAL process and device discovery

**Files:**
- Create: `Sources/ToolBox/AudioRouting/CoreAudioPropertyReader.swift`
- Create: `Sources/ToolBox/AudioRouting/AudioProcessRegistry.swift`
- Create: `Sources/ToolBox/AudioRouting/AudioDeviceRegistry.swift`
- Test: `Tests/ToolBoxTests/AudioRegistryProjectionTests.swift`

**Interfaces:**
- Consumes the snapshot types from Task 1.
- Produces `AudioProcessRegistry.snapshot`, `AudioDeviceRegistry.snapshot`, lifecycle `start()/stop()`, and pure projection helpers testable from supplied HAL records.

- [ ] Write tests for process projection, output-only filtering, stable UID projection, and unavailable-device retention.
- [ ] Run focused tests and confirm missing-helper failures.
- [ ] Implement typed `AudioObjectGetPropertyData` helpers plus listeners for process list, device list, default output, service restart, and process running-output.
- [ ] Run focused tests and confirm zero failures.

### Task 3: Realtime DSP and Objective-C++ engine boundary

**Files:**
- Create: `Sources/ToolBox/AudioRouting/AudioRouteDSP.hpp`
- Create: `Sources/ToolBox/AudioRouting/AudioRouteDSP.cpp`
- Create: `Sources/ToolBox/AudioRouting/AudioRouteEngine.h`
- Create: `Sources/ToolBox/AudioRouting/AudioRouteEngine.mm`
- Modify: `Sources/ToolBox/DisplayControl/Darwin/DisplayControlBridgingHeader.h`
- Modify: `project.yml`
- Test: `Tests/ToolBoxTests/AudioRouteDSPTests.swift`

**Interfaces:**
- Produces C bridge functions for deterministic buffer tests and `TBAudioRouteEngine` with `startRoute`, `updateGain`, `stopRoute`, and `stopAllRoutes`.

- [ ] Write Swift XCTest cases through the C bridge for `0%`, `100%`, `300%`, clipping count, stereo mix, and extra-channel silence.
- [ ] Run focused tests and confirm linker/missing-symbol failure.
- [ ] Implement allocation-free Float32 DSP over caller-owned buffers.
- [ ] Implement engine lifecycle using `AudioHardwareCreateProcessTap`, private Aggregate composition, IOProc creation/start, and reverse-order cleanup.
- [ ] Run focused tests and Debug build.

### Task 4: Main-actor routing service and failure recovery

**Files:**
- Create: `Sources/ToolBox/AudioRouting/AudioRoutingService.swift`
- Create: `Sources/ToolBox/AudioRouting/AudioRoutingMenuModel.swift`
- Test: `Tests/ToolBoxTests/AudioRoutingServiceTests.swift`

**Interfaces:**
- Consumes Tasks 1-3.
- Produces shared published rows/devices/permission state and mutation methods used by both UI surfaces.

- [ ] Write tests using fake registries/engine for gain-only updates, route rebuilds, device loss, process restart, engine failure, and stop cleanup.
- [ ] Run focused tests and confirm missing-service failures.
- [ ] Implement dependency-injected orchestration; serialize plan application and publish truthful inactive/waiting/starting/active/degraded/failed states.
- [ ] Run focused tests and full `ToolBoxTests`.

### Task 5: Real Process Tap smoke harness

**Files:**
- Create: `Sources/ToolBox/AudioRouting/AudioRoutingDiagnostics.swift`
- Test: manual runtime verification using the built ToolBox app and an active audio process.

**Interfaces:**
- Adds debug-only OSLog summaries for control-plane lifecycle and a settings status that identifies the active process/device without logging from IOProc.

- [ ] Build Debug with `NSAudioCaptureUsageDescription` present.
- [ ] Run ToolBox, authorize system audio capture, route a real audio process at `100%`, and confirm audio reaches the selected device.
- [ ] Change to `300%`, then stop ToolBox and confirm the original path resumes.
- [ ] Unplug the destination and confirm the service stops the tap and enters degraded state.
- [ ] Treat any permanent mute, process mismatch, or failed cleanup as a blocker before UI integration.

### Task 6: Menu popover controls

**Files:**
- Create: `Sources/ToolBox/AudioRouting/AudioRoutingPanel.swift`
- Modify: `Sources/ToolBox/PopoverContent.swift`
- Modify: `Sources/ToolBox/MenuPanelLayout.swift`
- Modify: `Sources/ToolBox/AppDelegate.swift`
- Test: `Tests/ToolBoxTests/AudioRoutingMenuModelTests.swift`
- Modify: `Tests/ToolBoxTests/MenuPanelLayoutTests.swift`

**Interfaces:**
- Consumes `AudioRoutingMenuModel`; emits only service mutations.

- [ ] Write tests for maximum four rows, configured/running ordering, 5% stepping, fixed panel-height contribution, and disabled/error states.
- [ ] Run focused tests and confirm failures.
- [ ] Implement the compact icon/name/minus/percentage/plus rows and settings navigation.
- [ ] Run focused tests and Debug build.

### Task 7: Detailed audio settings

**Files:**
- Create: `Sources/ToolBox/AudioRouting/AudioRoutingSettingsView.swift`
- Modify: `Sources/ToolBox/SettingsView.swift`
- Modify: `Sources/ToolBox/AppDelegate.swift`
- Test: `Tests/ToolBoxTests/AudioRoutingSettingsModelTests.swift`

**Interfaces:**
- Uses the same menu model/store; no direct HAL or UserDefaults calls.

- [ ] Write tests for search, exact percentage editing, reset to `100%`, output UID selection, and device-unavailable display.
- [ ] Run focused tests and confirm failures.
- [ ] Add the Audio settings tab and existing SettingsChrome-styled rows with slider, stepper/value, reset, picker, and truthful state.
- [ ] Run focused tests and Debug build.

### Task 8: Documentation and release verification

**Files:**
- Modify: `README.md`
- Modify: `Resources/Info.plist`
- Modify: `project.yml`

**Interfaces:**
- Documents the implemented permission, macOS 14.2 capability floor, 300% clipping behavior, output-only scope, and recovery behavior.

- [ ] Add `NSAudioCaptureUsageDescription` to generated and checked-in plist sources.
- [ ] Run the full test suite.
- [ ] Run `CONFIG=Debug OPEN=0 ./build.sh` and `OPEN=0 ./build.sh`.
- [ ] Run strict codesign verification on Debug and Release apps.
- [ ] Run `git diff --check` and review all changed files for swallowed errors, allocations/locks in IOProc, stale listeners, and cleanup ordering.
- [ ] Repeat real Zoom/helper, multi-device, hot-plug, permission, sleep/wake, and quit recovery tests; record any hardware-only gaps.
