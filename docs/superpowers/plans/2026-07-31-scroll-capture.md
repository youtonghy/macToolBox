# Scroll Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add reliable manual and automatic scrolling capture for the current region or Shift-union selection, with visible pause/recovery states, bounded disk/memory use and handoff to the existing annotation editor.

**Architecture:** `ScreenshotCoordinator` remains the sole public workflow owner and embeds a
main-actor `ScrollCaptureCoordinator` as a cancellable child session. Injected frame sampling,
stability detection, target activation, scrolling, overlap matching and incremental composition are
independent. Only a high-confidence forward match may append pixels.

**Tech Stack:** Swift 5, AppKit, ScreenCaptureKit, CoreGraphics, Accelerate, ImageIO, XCTest, XcodeGen, macOS 14+.

## Global Constraints

- Requires the completed screenshot capture/selection and annotation editor plans.
- Preserve unrelated dirty changes.
- Freeze one global-point ROI for the entire session; never re-query AX selection while scrolling.
- Require one stable PID/window/display/topology target; cross-window, cross-process and cross-display
  unions remain valid static screenshots but are ineligible for long capture.
- Default to automatic scrolling and degrade to manual scrolling when event posting is unavailable.
- Keep original captured pixels; use reduced luma data only for stability and overlap analysis.
- Append only on a forward, confidence-qualified match.
- Stop at 60,000 output pixels or estimated 512 MiB RGBA storage, whichever comes first.
- Use the editor's tiled source/renderer/exporter and keep resident working set below 256 MiB,
  excluding a separate OCR worker.
- Store strips in a private temporary session directory and clean stale sessions older than 24 hours on launch.
- Use test-first development, typed errors and cooperative cancellation; do not commit unless separately requested.
- Run `xcodegen generate` immediately before every `xcodebuild` command after adding files.

---

### Task 1: Pure frame stability, overlap matching and fixed-content masking

**Files:**
- Create: `Sources/ToolBox/Screenshot/Scroll/ScrollCaptureModels.swift`
- Create: `Sources/ToolBox/Screenshot/Scroll/FrameStabilityDetector.swift`
- Create: `Sources/ToolBox/Screenshot/Scroll/OverlapMatcher.swift`
- Create: `Sources/ToolBox/Screenshot/Scroll/StableContentMask.swift`
- Create: `Tests/ToolBoxTests/FrameStabilityDetectorTests.swift`
- Create: `Tests/ToolBoxTests/OverlapMatcherTests.swift`
- Add fixtures: `Tests/ToolBoxTests/Fixtures/ScrollCapture/`

**Interfaces:**
- Produces: `ScrollMatchingConfiguration`, `LumaFrame`, `FrameStability`, `OverlapMatch`, `StableContentMask`.
- Consumes: fixed-size downsampled luma frames and monotonic sample timestamps.

- [ ] **Step 1: Add deterministic fixture sequences**

Create fixed PNG sequences for known vertical offsets, no movement, fixed header/footer, a blinking cursor, small animated region, reverse movement, scale change, low-texture content and unrelated content. Record expected new-row counts and whether each sequence should append, pause or complete.

- [ ] **Step 2: Write failing stability and matcher tests**

Assert:

- stability requires consecutive below-threshold samples, not one quiet frame;
- a known forward offset returns exact overlap/new-row counts;
- identical frames return no new content;
- fixed header/footer rows do not bias the offset;
- sparse animation is masked without hiding real scroll changes;
- reverse motion is classified separately;
- ambiguity and unrelated frames return low confidence;
- non-equal dimensions and invalid buffers fail before matching.

- [ ] **Step 3: Run focused tests to verify RED**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/FrameStabilityDetectorTests \
  -only-testing:ToolBoxTests/OverlapMatcherTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure for missing scroll-matching types.

- [ ] **Step 4: Implement bounded matching**

Convert preview frames to a fixed-width luma pyramid using Accelerate. Compare the previous lower band to candidate positions in the current upper band with normalized row error and texture weighting. Refine the best coarse candidate at full preview resolution and derive confidence from absolute error plus separation from the second-best candidate.

`StableContentMask` tracks rows/blocks unchanged across multiple accepted frames and excludes persistent headers/footers from scoring. Exclude only small unstable blocks for cursor/animation tolerance. Put all thresholds, search ranges and required sample counts in `ScrollMatchingConfiguration`; calibrate the checked-in defaults against every fixture instead of scattering constants.

- [ ] **Step 5: Run matcher tests to verify GREEN**

Run the Step 3 command. Expected: all stability and matching fixtures pass.

### Task 2: Incremental strip store, resource limits and lazy final image

**Files:**
- Create: `Sources/ToolBox/Screenshot/Scroll/ScrollCaptureResourceBudget.swift`
- Create: `Sources/ToolBox/Screenshot/Scroll/ScrollCaptureStripStore.swift`
- Create: `Sources/ToolBox/Screenshot/Scroll/IncrementalImageComposer.swift`
- Create: `Sources/ToolBox/Screenshot/Scroll/ScrollCaptureCleanup.swift`
- Create: `Tests/ToolBoxTests/ScrollCaptureResourceBudgetTests.swift`
- Create: `Tests/ToolBoxTests/IncrementalImageComposerTests.swift`
- Create: `Tests/ToolBoxTests/ScrollCaptureCleanupTests.swift`

**Interfaces:**
- Produces: `ScrollCaptureResourceBudget`, append-only strips, downsampled preview and a read-only
  file-backed `ScreenshotImageSource`.
- Consumes: initial ROI image and exact non-overlap row ranges from Task 1.

- [ ] **Step 1: Write failing budget and composer tests**

Cover checked width/height/bytes-per-row multiplication, the 60,000-pixel cap, 512 MiB cap,
one-row-before/at/after limits, strip order, partial final strip, disk-full rollback, corrupt metadata,
cancellation, pixel continuity, bounded tile reads and a 60,000-pixel source whose preview/export path
never requests a full-image buffer.

- [ ] **Step 2: Run focused tests to verify RED**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/ScrollCaptureResourceBudgetTests \
  -only-testing:ToolBoxTests/IncrementalImageComposerTests \
  -only-testing:ToolBoxTests/ScrollCaptureCleanupTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure for missing resource and composer types.

- [ ] **Step 3: Implement private session storage**

Create each session under the app's Caches directory with mode `0700`; write files with mode `0600`. Store an immutable initial strip followed by only newly accepted rows. Write strip bytes and metadata to temporary siblings, fsync, then rename before publishing the new logical height. Never expose a partially appended strip.

Build preview thumbnails incrementally from strips. Finalization creates the annotation plan's
read-only file-backed `ScreenshotImageSource`. Its bounded pixel API reads only requested tiles; the
editor and exporter may use mmap backing but may not allocate a second full RGBA context.

- [ ] **Step 4: Enforce cleanup and limits**

Before every append, calculate the next logical height and RGBA byte estimate with overflow checks. At either approved limit, return `.resourceLimitReached` with a usable partial result. Delete session data after export/editor close; on launch delete only recognized session directories older than 24 hours and never follow symlinks.

- [ ] **Step 5: Run storage tests to verify GREEN**

Run the Step 2 command. Expected: all budget, pixel and cleanup tests pass.

### Task 3: Manual/automatic scroll driver and target guard

**Files:**
- Create: `Sources/ToolBox/Screenshot/Scroll/ScrollDriver.swift`
- Create: `Sources/ToolBox/Screenshot/Scroll/ScrollTargetGuard.swift`
- Create: `Sources/ToolBox/Screenshot/Scroll/ScrollCaptureTarget.swift`
- Create: `Sources/ToolBox/Screenshot/Scroll/ScrollTargetActivation.swift`
- Create: `Sources/ToolBox/Screenshot/Scroll/ScrollEventAccess.swift`
- Create: `Tests/ToolBoxTests/ScrollDriverTests.swift`
- Create: `Tests/ToolBoxTests/ScrollTargetGuardTests.swift`
- Create: `Tests/ToolBoxTests/ScrollCaptureTargetTests.swift`
- Modify: `Sources/ToolBox/Permissions.swift`

**Interfaces:**
- Produces: `ScrollCaptureTargetSnapshot`, eligibility, target activation/restoration,
  `ScrollDriving.scroll(step:target:)` and event-posting permission status.
- Consumes: fixed ROI, original target PID/window/display/topology snapshot and injected CGEvent functions.

- [ ] **Step 1: Write failing driver and guard tests**

Assert automatic mode uses small downward pixel-unit steps centered inside the ROI, never posts when
access is denied, can be cancelled, rate-limits events and stops after invalidation. Test eligibility:
all selected elements must share non-nil PID/window ID, ROI must remain within that visible window and
one display/topology generation, and manual regions must resolve to one containing window. Reject
cross-window/process/display unions. Test PID exit, front-window replacement, window movement/resize,
display change, ROI clipping, activation failure, previous-app restoration and manual-mode no-op.

- [ ] **Step 2: Run focused tests to verify RED**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/ScrollDriverTests \
  -only-testing:ToolBoxTests/ScrollTargetGuardTests \
  -only-testing:ToolBoxTests/ScrollCaptureTargetTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure for missing driver and target guard.

- [ ] **Step 3: Implement permission and target boundaries**

Build `ScrollCaptureTargetSnapshot` only from one stable PID/window/display/topology source. Wrap
`CGPreflightPostEventAccess` and its user-triggered request API; if denied, return `.manualRequired`
without requesting Input Monitoring. Before session start, order out ToolBox overlays/editor, activate
the target application/window and revalidate it. `ScrollTargetGuard` repeats validation before capture
and every event; restoration is idempotent on every exit path.

- [ ] **Step 4: Implement automatic and manual drivers**

The automatic driver creates a cancellable vertical scroll-wheel event with configurable step size and cadence, posts only while the pointer/target remains valid, then yields to stability sampling. Manual mode posts nothing and waits for user-driven movement. Both modes expose the same “movement requested / waiting / stopped” contract to the state machine.

- [ ] **Step 5: Run driver tests to verify GREEN**

Run the Step 2 command. Expected: all permission, event and target tests pass.

### Task 4: Scroll-capture state machine and screenshot-frame integration

**Files:**
- Create: `Sources/ToolBox/Screenshot/Scroll/ScrollCaptureCoordinator.swift`
- Create: `Sources/ToolBox/Screenshot/Scroll/ScrollCaptureFrameProvider.swift`
- Create: `Tests/ToolBoxTests/ScrollCaptureCoordinatorTests.swift`
- Modify: `Sources/ToolBox/Screenshot/Capture/ScreenCaptureProvider.swift`
- Modify: `Sources/ToolBox/Screenshot/ScreenshotCoordinator.swift`

**Interfaces:**
- Consumes: confirmed ROI/target snapshot, capture provider, stability detector, matcher, driver and incremental composer.
- Produces: `ScrollCaptureState`, progress preview, retry/switch-to-manual/finish-partial/cancel actions and editor handoff.

- [ ] **Step 1: Write failing state-transition tests**

Cover:

- `idle -> acquiringTarget -> capturingInitialFrame`;
- automatic permission denial switching to manual;
- scroll, stability wait, match and append loop;
- three consecutive accepted no-new-content frames completing at bottom;
- low-confidence pause without append;
- reverse-scroll pause;
- target/topology change failure;
- target activation failure without capturing;
- selection overlay closure and editor order-out before target activation;
- parent `ScreenshotWorkflowState.longCapturing` mapping and cancel propagation;
- editor/previous-app restoration after complete, cancel and failure;
- retry after low confidence;
- finish with partial image;
- resource-limit completion;
- cancellation and app-stop cleanup;
- stale async generations not mutating a newer session.

- [ ] **Step 2: Run coordinator tests to verify RED**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/ScrollCaptureCoordinatorTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure for missing coordinator.

- [ ] **Step 3: Implement ROI frame capture**

Reuse the capture plan's display geometry and ScreenCaptureKit provider to capture the same global-point ROI each time. Convert to one canonical pixel size established by the initial frame. Reject scale, dimension, color-space or topology changes rather than silently resampling a moved target.

- [ ] **Step 4: Implement the state machine**

Use these internal child states: `idle`, `acquiringTarget`, `capturingInitialFrame`, `scrolling`,
`waitingForStability`, `matchingOverlap`, `appending`, `paused(issue)`, `completed`, `cancelled`,
`failed(issue)`. The parent exposes only its mapped `ScreenshotWorkflowState.longCapturing` summary.

The child coordinator is not exposed from AppDelegate or views; `ScreenshotCoordinator` starts it,
maps presentation state, propagates cancel and owns the sole editor handoff. All transitions run on the
main actor. Each loop owns a generation/token. Only a qualified forward match may append. Three
high-confidence no-new-content matches complete; low confidence and reverse motion pause. Users may
retry, switch to manual, finish partial or cancel.

- [ ] **Step 5: Integrate editor handoff**

On completion or finish-partial, create a `ScreenshotDocument` with the file-backed source and scroll
metadata. Restore/show the editor only after target capture stops. Annotation/OCR stays in source
pixels. On editor close, release the source before deleting session storage.

- [ ] **Step 6: Run coordinator and capture suites**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/ScrollCaptureCoordinatorTests \
  -only-testing:ToolBoxTests/CaptureGeometryTests \
  -only-testing:ToolBoxTests/ScreenshotImageComposerTests CODE_SIGNING_ALLOWED=NO
```

Expected: scroll coordinator tests plus existing capture geometry/compositor tests pass.

### Task 5: Capture controls, settings, diagnostics and acceptance

**Files:**
- Create: `Sources/ToolBox/Screenshot/Scroll/ScrollCaptureControlView.swift`
- Create: `Sources/ToolBox/Screenshot/Scroll/ScrollCaptureSettingsStore.swift`
- Create: `Tests/ToolBoxTests/ScrollCaptureSettingsStoreTests.swift`
- Modify: `Sources/ToolBox/Screenshot/Selection/ScreenshotSelectionView.swift`
- Modify: `Sources/ToolBox/Screenshot/Editor/ScreenshotEditorView.swift`
- Modify: `Sources/ToolBox/Screenshot/ScreenshotSettingsView.swift`
- Modify: `Sources/ToolBox/AppDelegate.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: a confirmed current region and `ScrollCaptureCoordinator`.
- Produces: start-long-capture command, progress/status UI, recovery controls and persisted default mode.

- [ ] **Step 1: Write failing settings and UI-state tests**

Test default automatic mode, corrupt-setting fallback, ineligible-selection explanation,
automatic-to-manual degradation, parent/child presentation mapping, progress height/limit reporting,
pause actions, double-start suppression and permission visibility.

- [ ] **Step 2: Run focused tests to verify RED**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/ScrollCaptureSettingsStoreTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure for missing settings store.

- [ ] **Step 3: Add complete session controls**

Add a long-capture command only when capture metadata yields an eligible target; otherwise show the
specific reason. If started from the editor, order it out before activating the target. During capture,
show mode, height, compact preview, finish and cancel in a nonactivating panel outside the ROI so the
target keeps receiving manual/automatic scroll. Paused state exposes only valid recovery actions.

- [ ] **Step 4: Add functional settings and lifecycle cleanup**

Add automatic/manual default mode, event-posting permission status and a permission action. App
startup runs stale-session cleanup; shutdown cancels through the parent coordinator, stops event
posting, restores/hides windows as appropriate and releases image providers before cleanup.

- [ ] **Step 5: Run full automated verification**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project ToolBox.xcodeproj -scheme ToolBox -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project ToolBox.xcodeproj -scheme ToolBox -configuration Release \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
git diff --check
```

Expected: all tests and both builds pass with no diff errors.

- [ ] **Step 6: Complete manual acceptance matrix**

Test Safari, Chrome, Finder, System Settings, Preview/PDF, chat lists and Electron apps in automatic and manual modes; fixed headers, videos/animations, slow loading, reverse scrolling and bottom detection; Retina/non-Retina/mixed-scale displays; window move/resize, Spaces, full screen, target quit and display hot-plug; permission denial; finish-partial/cancel; 60,000-pixel and 512 MiB limits; editor annotation, OCR, PNG copy/save and stale-session cleanup after a forced quit.
