# Automatic Focus Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent automatic focus mode that follows the Accessibility focused window, falls back to the mouse display, and dims every other display with passive overlay windows.

**Architecture:** A main-actor `FocusModeCoordinator` owns persisted state and reconciles a small system-observer interface with a small overlay-manager interface. Pure geometry resolves AX top-left coordinates into an active AppKit display, while platform-specific AX and AppKit window details remain behind focused modules.

**Tech Stack:** Swift 5, AppKit, ApplicationServices Accessibility APIs, Combine, UserDefaults, XCTest, XcodeGen, macOS 14.

## Global Constraints

- Preserve all existing uncommitted user changes; never reset or rewrite unrelated files.
- Work serially in the current workspace because the approved feature integrates with dirty `AppDelegate.swift`, `SettingsView.swift`, and window behavior.
- Do not modify physical display brightness or the existing DDC schedule/manual-write policy.
- Do not add manual focus, hover reveal, dim delay, preset levels, a global shortcut, or Input Monitoring requirements.
- UI copy remains Chinese and follows the existing settings chrome and circular control button patterns.
- `FocusModeCoordinator` and AppKit/AX lifecycle work run on the main actor.
- Use test-first red-green-refactor for every behavior-bearing production module.
- Do not commit unless the user separately requests it.

---

## File Structure

- Create `Sources/ToolBox/FocusMode/FocusModeModels.swift`: configuration, permission, system snapshot, screen geometry, coordinate conversion, and focus-target resolution.
- Create `Sources/ToolBox/FocusMode/FocusModeStore.swift`: injected `UserDefaults` persistence and opacity normalization.
- Create `Sources/ToolBox/FocusMode/FocusOverlayManager.swift`: passive overlay windows and idempotent desired-window reconciliation.
- Create `Sources/ToolBox/FocusMode/SystemFocusModeObserver.swift`: workspace, AXObserver, mouse fallback, health timer, screen, and sleep/wake event source.
- Create `Sources/ToolBox/FocusMode/FocusModeCoordinator.swift`: public observable state, persistence, permission prompting, and reconciliation.
- Create `Tests/ToolBoxTests/FocusTargetResolverTests.swift`: coordinate and active-display rules.
- Create `Tests/ToolBoxTests/FocusModeStoreTests.swift`: persisted configuration behavior.
- Create `Tests/ToolBoxTests/FocusModeCoordinatorTests.swift`: lifecycle, fallback, overlay planning, and latest-state behavior.
- Modify `Sources/ToolBox/AppDelegate.swift`: construct, inject, start, and stop the coordinator.
- Modify `Sources/ToolBox/PopoverContent.swift`: add the third bottom-right control.
- Modify `Sources/ToolBox/SettingsView.swift`: add display settings, permission state, slider, and home feature row.
- Modify `README.md`: document behavior, permissions, source location, and limits.

---

### Task 1: Pure focus resolution and configuration persistence

**Files:**
- Create: `Tests/ToolBoxTests/FocusTargetResolverTests.swift`
- Create: `Tests/ToolBoxTests/FocusModeStoreTests.swift`
- Create: `Sources/ToolBox/FocusMode/FocusModeModels.swift`
- Create: `Sources/ToolBox/FocusMode/FocusModeStore.swift`

**Interfaces:**
- Produces: `FocusModeConfiguration`, `FocusPermissionState`, `FocusScreenGeometry`, `FocusSystemSnapshot`, `FocusTargetResolver.resolve(...)`, and `FocusModeStore.load()/save(_:)`.
- Consumes: `CGDirectDisplayID`, `CGRect`, `CGPoint`, `pid_t`, and injected `UserDefaults`.

- [ ] **Step 1: Write resolver tests that fail because the types do not exist**

Use literal fixtures for two horizontal screens, screens above and below the primary, cross-screen windows, equal intersections, own-PID preservation, invalid AX frames, mouse/last/primary fallbacks, and zero/one-screen inputs.

- [ ] **Step 2: Write store tests that fail because the store does not exist**

Use a unique `UserDefaults(suiteName:)`. Assert missing keys load `enabled=false, overlayOpacity=0.55`, round trips preserve values, and `nan`, `0.1`, and `0.95` normalize to `0.55`, `0.20`, and `0.85` respectively.

- [ ] **Step 3: Generate the project and run focused tests to verify RED**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/FocusTargetResolverTests \
  -only-testing:ToolBoxTests/FocusModeStoreTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure for missing `Focus*` production types, proving the tests exercise absent behavior.

- [ ] **Step 4: Implement the minimal pure models and store**

`FocusTargetResolver` provides:

```swift
static func appKitRect(fromAXRect rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect
static func resolve(
    screens: [FocusScreenGeometry],
    snapshot: FocusSystemSnapshot,
    ownProcessID: pid_t,
    lastExternalDisplayID: CGDirectDisplayID?
) -> CGDirectDisplayID?
```

Reject empty/non-finite AX rects. Use `primaryScreenHeight - rect.maxY` for Y conversion, literal intersection area, and the approved tie-break order. Store keys are `focusMode.enabled` and `focusMode.overlayOpacity`.

- [ ] **Step 5: Run focused tests to verify GREEN and refactor names only while green**

Run the Step 3 command. Expected: both suites pass with zero failures.

---

### Task 2: Coordinator state machine and overlay plan

**Files:**
- Create: `Tests/ToolBoxTests/FocusModeCoordinatorTests.swift`
- Create: `Sources/ToolBox/FocusMode/FocusModeCoordinator.swift`
- Extend: `Sources/ToolBox/FocusMode/FocusModeModels.swift`

**Interfaces:**
- Consumes: `FocusModeStore`, `FocusModeSystemObserving`, `FocusOverlayManaging`, `FocusTargetResolver`, and a screen-provider closure.
- Produces: `@MainActor FocusModeCoordinator` with `isEnabled`, `overlayOpacity`, `permissionState`, `setEnabled`, `setOverlayOpacity`, `requestAccessibilityPermission`, `openAccessibilitySettings`, `start`, and `stop`.

- [ ] **Step 1: Write coordinator tests against explicit fakes**

The fake observer exposes a complete `FocusSystemSnapshot` and emits a real `onChange` callback. The fake overlay manager stores its current dimmed IDs and opacity, modeling the external window side effect.

Cover persisted startup without prompting, user enable prompting once while mouse fallback remains active, authorization upgrade without retoggle, own-PID preservation, opacity persistence, disabled/sleeping/single-screen clearing, duplicate snapshot deduplication, rapid latest-target-wins, and idempotent lifecycle.

- [ ] **Step 2: Run the coordinator suite to verify RED**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/FocusModeCoordinatorTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure for missing coordinator/protocol interfaces.

- [ ] **Step 3: Implement the minimal coordinator and protocols**

Define:

```swift
@MainActor protocol FocusModeSystemObserving: AnyObject {
    var onChange: (() -> Void)? { get set }
    var snapshot: FocusSystemSnapshot { get }
    func start()
    func stop()
    func requestAccessibilityPermission()
    func openAccessibilitySettings()
}

@MainActor protocol FocusOverlayManaging: AnyObject {
    var dimmedDisplayIDs: Set<CGDirectDisplayID> { get }
    func apply(screens: [FocusScreenGeometry], focusedDisplayID: CGDirectDisplayID?, opacity: Double)
    func clear()
}
```

The coordinator owns the only `reconcile()` function, updates permission state from each snapshot, applies the own-PID special case through the resolver, and compares desired state before issuing overlay changes.

- [ ] **Step 4: Run Task 1 and Task 2 focused tests to verify GREEN**

Run Step 2 plus the two Task 1 `only-testing` arguments. Expected: all three suites pass.

---

### Task 3: Passive AppKit overlay windows

**Files:**
- Extend: `Tests/ToolBoxTests/FocusModeCoordinatorTests.swift`
- Create: `Sources/ToolBox/FocusMode/FocusOverlayManager.swift`

**Interfaces:**
- Consumes: `FocusOverlayManaging`, `FocusScreenGeometry`, opacity `0.20...0.85`.
- Produces: `FocusOverlayManager` and private `FocusOverlayWindow`.

- [ ] **Step 1: Add a failing real overlay-manager lifecycle test**

On the main actor, initialize `FocusOverlayManager(animationDuration: 0)` with two synthetic screen frames. Apply focused ID `1`, assert `dimmedDisplayIDs == [2]`; switch to `2`, assert `[1]`; change opacity and assert IDs remain `[1]`; clear and assert empty.

- [ ] **Step 2: Run the coordinator suite to verify RED**

Expected: compile failure for missing `FocusOverlayManager`.

- [ ] **Step 3: Implement passive windows and latest-generation cleanup**

Create borderless windows that override `canBecomeKey/canBecomeMain` to `false`; set black background, `ignoresMouseEvents=true`, `hidesOnDeactivate=false`, no shadow, `.screenSaver` level, full screen frame, and the approved collection behaviors. Keep a generation counter so an obsolete fade-out completion cannot close a window made current again by a newer reconcile.

- [ ] **Step 4: Run the focused suite to verify GREEN**

Expected: overlay lifecycle and coordinator tests pass without activating the app or requiring a real second display.

---

### Task 4: Event-driven AX and fallback observer

**Files:**
- Extend: `Tests/ToolBoxTests/FocusModeCoordinatorTests.swift`
- Create: `Sources/ToolBox/FocusMode/SystemFocusModeObserver.swift`

**Interfaces:**
- Implements: `FocusModeSystemObserving`.
- Consumes: `Permissions`, `NSWorkspace`, `NSEvent`, display/sleep notifications, `AXUIElement`, and `AXObserver`.

- [ ] **Step 1: Add failing tests for observer-independent AX policies**

Extract and test a pure `FocusAXRegistrationPolicy` that treats `.success` and `.notificationAlreadyRegistered` as installed, `.notificationUnsupported` as recoverable, and other AX errors as diagnostic failures.

- [ ] **Step 2: Run the focused suite to verify RED**

Expected: compile failure for missing AX policy/system observer.

- [ ] **Step 3: Implement the system observer**

Observe frontmost app changes; attach an app-specific AX observer and common-mode run-loop source; register focused-window, moved, resized, and destroyed notifications; read AX position/size; ignore own PID for attachment; emit mouse fallback changes only when needed; run a 2-second health check; observe display/sleep/wake; reuse `Permissions`; and remove every resource in idempotent `stop()`.

- [ ] **Step 4: Compile and run all focus tests**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/FocusTargetResolverTests \
  -only-testing:ToolBoxTests/FocusModeStoreTests \
  -only-testing:ToolBoxTests/FocusModeCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: all focus tests pass and AX/AppKit code compiles for macOS 14.

---

### Task 5: Lifecycle and SwiftUI integration

**Files:**
- Modify: `Sources/ToolBox/AppDelegate.swift`
- Modify: `Sources/ToolBox/PopoverContent.swift`
- Modify: `Sources/ToolBox/SettingsView.swift`

**Interfaces:**
- Consumes: production coordinator, overlay manager, and system observer.
- Produces: the approved third control and Display settings section.

- [ ] **Step 1: Wire coordinator lifecycle without changing existing feature state**

Construct dependencies in `AppDelegate`; pass the coordinator to both root views; call `start()` after launch and `stop()` during non-audio shutdown. Preserve every existing dirty edit.

- [ ] **Step 2: Add the bottom-right focus button**

Append `scope` after “后台干” with explicit coordinator binding, teal accent, title `聚焦模式`, and subtitle `突出当前使用的显示器`. Do not add a right-click menu item.

- [ ] **Step 3: Add the display settings section**

Add the mode toggle, `ScrollWheelSlider` from `0.20...0.85` step `0.01`, integer percent text, permission badge, and `打开系统设置` button when missing. Add “聚焦模式” to the home feature list. Keep the section visible without DDC displays.

- [ ] **Step 4: Run focus tests and Debug build**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/FocusTargetResolverTests \
  -only-testing:ToolBoxTests/FocusModeStoreTests \
  -only-testing:ToolBoxTests/FocusModeCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO
xcodebuild build -project ToolBox.xcodeproj -scheme ToolBox -configuration Debug CODE_SIGNING_ALLOWED=NO
```

Expected: tests pass and build succeeds with no new warnings.

---

### Task 6: Documentation, full verification, and quality review

**Files:**
- Modify: `README.md`
- Review: all files listed above plus the approved design and this plan.

- [ ] **Step 1: Update nearby README sections**

Document automatic mode, persistent control, settings slider, Accessibility permission, mouse fallback, source module, and that overlays do not change hardware brightness or power use.

- [ ] **Step 2: Run the complete test and build matrix**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project ToolBox.xcodeproj -scheme ToolBox -configuration Debug CODE_SIGNING_ALLOWED=NO
git diff --check
```

Expected: all tests pass, Debug build succeeds, and diff check is clean.

- [ ] **Step 3: Review architecture and safety**

Confirm no DDC writes were added, no event monitor intercepts clicks/keys, all AX resources are removed, stale animations are generation-guarded, errors are rate-limited, opacity is finite/clamped, self-focus cannot steal the target, and unrelated dirty changes remain intact.

- [ ] **Step 4: Record unautomated checks**

Report environment availability for two displays and Accessibility. If unavailable, leave manual checks explicit for grant/revoke, click-through switching, vertical layouts, Spaces/full-screen, Stage Manager, hot-plug, sleep/wake, restart restore, and simultaneous screen wipe.

---

## Plan Self-Review

- Spec coverage: every approved decision maps to Tasks 1-6; manual-only multi-display cases remain explicit.
- Placeholder scan: no step relies on TBD/TODO or an undefined neighboring interface.
- Type consistency: coordinator protocols are defined in Task 2 and implemented by Tasks 3-4; UI consumes only the coordinator interface.
- Scope: one feature slice with one lifecycle owner; no unrelated DDC, media-key, settings-navigation, or window refactor.

