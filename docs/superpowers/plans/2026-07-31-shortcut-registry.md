# Unified Shortcut Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single fixed-ID Carbon hot key wrapper with a persistent multi-action registry that supports a configurable region-screenshot shortcut and a protected screen-wipe exit shortcut.

**Architecture:** Pure shortcut rules and versioned persistence feed one main-actor Carbon registry. The registry owns one event handler, assigns one stable `EventHotKeyID` per action, decodes the event ID before dispatch, and applies binding changes transactionally.

**Tech Stack:** Swift 5, Carbon.HIToolbox, AppKit, SwiftUI, UserDefaults, XCTest, XcodeGen, macOS 14+.

## Global Constraints

- Preserve unrelated dirty audio-routing and documentation changes.
- Follow existing closure-table system injection and unique UserDefaults suite test patterns.
- Default region capture is `⌃⌥S`; screen-wipe exit remains `⌃⌥⌘Esc`.
- The screen-wipe exit rule may be rebound but never disabled.
- Media keys remain in `DisplayControlMediaKeyController`.
- Use test-first red-green-refactor for behavior-bearing code.
- Run `xcodegen generate` immediately before every `xcodebuild` command after adding files.
- Do not commit unless the user separately requests it.

---

### Task 1: Shortcut rules and versioned persistence

**Files:**
- Create: `Sources/ToolBox/Shortcuts/ShortcutModels.swift`
- Create: `Sources/ToolBox/Shortcuts/ShortcutRuleStore.swift`
- Create: `Tests/ToolBoxTests/ShortcutRuleStoreTests.swift`

**Interfaces:**
- Produces: `ShortcutActionID`, `ShortcutModifiers`, `ShortcutBinding`, `ShortcutRule`, `ShortcutRuleLoadResult`, `ShortcutRuleStore.load()` and `save(_:)`.
- Consumes: injected `UserDefaults` and storage key.

- [ ] **Step 1: Write failing default and persistence tests**

```swift
import Carbon.HIToolbox
import XCTest
@testable import ToolBox

final class ShortcutRuleStoreTests: XCTestCase {
    func testMissingDataReturnsApprovedDefaults() {
        let store = makeStore()
        let result = store.load()

        XCTAssertNil(result.issue)
        XCTAssertEqual(result.rules, [
            .init(
                id: .captureRegion,
                binding: .init(
                    keyCode: UInt32(kVK_ANSI_S),
                    modifiers: [.control, .option]
                ),
                isEnabled: true
            ),
            .init(
                id: .screenWipeExit,
                binding: .init(
                    keyCode: UInt32(kVK_Escape),
                    modifiers: [.control, .option, .command]
                ),
                isEnabled: true
            ),
        ])
    }

    func testSaveRejectsDisabledProtectedRule() {
        let store = makeStore()
        var rules = store.load().rules
        rules[rules.firstIndex(where: { $0.id == .screenWipeExit })!].isEnabled = false

        XCTAssertThrowsError(try store.save(rules)) {
            XCTAssertEqual($0 as? ShortcutRuleStoreError, .protectedRuleDisabled)
        }
    }
}
```

Add round-trip, duplicate action, duplicate binding, missing protected rule, unknown schema and corrupt-data cases. `makeStore()` creates a unique suite and removes its domain in `tearDown`.

- [ ] **Step 2: Run the focused suite to verify RED**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/ShortcutRuleStoreTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure because shortcut rule types do not exist.

- [ ] **Step 3: Implement the pure models and store**

Use these exact cases:

```swift
enum ShortcutActionID: String, Codable, CaseIterable, Sendable {
    case captureRegion
    case screenWipeExit
}

struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt32
    static let command = Self(rawValue: UInt32(cmdKey))
    static let option = Self(rawValue: UInt32(optionKey))
    static let control = Self(rawValue: UInt32(controlKey))
    static let shift = Self(rawValue: UInt32(shiftKey))
}
```

Persist one envelope with `schemaVersion = 1`. Reject empty modifiers, duplicate action IDs, enabled duplicate bindings, and a missing/disabled screen-wipe exit rule. Corrupt or unknown data returns approved defaults plus a visible load issue; it does not silently treat corrupt bytes as valid empty rules.

- [ ] **Step 4: Run the store suite to verify GREEN**

Run the Step 2 command. Expected: all `ShortcutRuleStoreTests` pass.

### Task 2: One Carbon registry with transactional rebinding

**Files:**
- Create: `Sources/ToolBox/Shortcuts/ShortcutRegistry.swift`
- Create: `Tests/ToolBoxTests/ShortcutRegistryTests.swift`
- Delete after migration in Task 4: `Sources/ToolBox/HotKeyController.swift`

**Interfaces:**
- Consumes: `[ShortcutRule]` and injected `ShortcutCarbonSystem`.
- Produces: `ShortcutRegistry.start(rules:)`, `stop()`, `apply(rule:)`, `isRegistered(_:)`, `onAction`.

- [ ] **Step 1: Write failing ID-routing and rollback tests**

```swift
@MainActor
final class ShortcutRegistryTests: XCTestCase {
    func testEventIDDispatchesOnlyMatchingAction() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        var actions: [ShortcutActionID] = []
        registry.onAction = { actions.append($0) }

        try registry.start(rules: ShortcutRule.defaults)
        recorder.fire(id: ShortcutActionID.captureRegion.carbonID)

        XCTAssertEqual(actions, [.captureRegion])
    }

    func testFailedRebindKeepsOldRegistration() throws {
        let recorder = ShortcutCarbonSystemRecorder()
        let registry = ShortcutRegistry(system: recorder.system)
        try registry.start(rules: ShortcutRule.defaults)
        recorder.nextRegisterStatus = OSStatus(eventHotKeyExistsErr)

        XCTAssertThrowsError(try registry.apply(
            rule: .init(
                id: .captureRegion,
                binding: .init(keyCode: 1, modifiers: [.command]),
                isEnabled: true
            )
        ))
        XCTAssertTrue(registry.isRegistered(.captureRegion))
        XCTAssertEqual(recorder.activeBinding(for: .captureRegion), .approvedCaptureDefault)
    }
}
```

Also cover install idempotency, two actions registered together, unknown event ID returning `eventNotHandledErr`, disabled capture unregistration, protected rule rejection, stop idempotency and deinit cleanup.

- [ ] **Step 2: Run the focused suite to verify RED**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/ShortcutRegistryTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure for missing registry types.

- [ ] **Step 3: Implement the Carbon adapter and registry**

`ShortcutCarbonSystem.installHandler` passes both callback context and `EventRef`. The callback retrieves `kEventParamDirectObject` as `typeEventHotKeyID`, maps `id` to `ShortcutActionID`, and invokes only that action.

Use stable IDs:

```swift
extension ShortcutActionID {
    var carbonID: UInt32 {
        switch self {
        case .captureRegion: 1
        case .screenWipeExit: 2
        }
    }
}
```

For rebind, register the new combination under a temporary unused ID, unregister the old ref only after success, then replace the temporary ref with the action record. If Carbon cannot atomically reuse the stable ID, retain the temporary ID in the in-memory `idToAction` map; persisted identity remains `ShortcutActionID`.

- [ ] **Step 4: Run registry and store suites to verify GREEN**

Run Task 1 and Task 2 focused suites. Expected: all pass.

### Task 3: Shortcut settings UI

**Files:**
- Create: `Sources/ToolBox/Shortcuts/ShortcutSettingsModel.swift`
- Create: `Sources/ToolBox/Shortcuts/ShortcutRecorderView.swift`
- Create: `Sources/ToolBox/Shortcuts/ShortcutSettingsView.swift`
- Create: `Tests/ToolBoxTests/ShortcutSettingsModelTests.swift`
- Modify: `Sources/ToolBox/SettingsView.swift`
- Modify: `Sources/ToolBox/AppDelegate.swift`

**Interfaces:**
- Consumes: `ShortcutRegistry`, `ShortcutRuleStore`.
- Produces: observable rules, conflict state, `setEnabled`, `record`, and `restoreDefault`.

- [ ] **Step 1: Write failing model tests**

Test that capture can disable, wipe cannot disable, internal duplicates are rejected before Carbon, a system conflict retains the old displayed binding, successful change saves once, restore-default uses approved bindings, and a corrupt store issue remains visible.

- [ ] **Step 2: Run tests to verify RED**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/ShortcutSettingsModelTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure for missing settings model.

- [ ] **Step 3: Implement the settings model and recorder**

`ShortcutRecorderView` is an `NSViewRepresentable` that becomes first responder only while recording, consumes one key-down, requires at least one supported modifier, treats Escape as cancel, and never installs a global monitor.

Add a `shortcuts` settings tab titled `快捷键` with `keyboard` SF Symbol. Rows display action title, enabled toggle where allowed, formatted binding, record button, reset button and concise inline conflict text. Add a separate informational media-key section without moving its backend.

- [ ] **Step 4: Run focused tests and build**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/ShortcutSettingsModelTests CODE_SIGNING_ALLOWED=NO
xcodebuild build -project ToolBox.xcodeproj -scheme ToolBox -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: tests and Debug build succeed.

### Task 4: Migrate screen wipe and wire the screenshot action

**Files:**
- Modify: `Sources/ToolBox/ScreenWipe/ScreenWipeCoordinator.swift`
- Modify: `Sources/ToolBox/AppDelegate.swift`
- Modify: `Tests/ToolBoxTests/HotKeyControllerTests.swift`
- Rename test to: `Tests/ToolBoxTests/ScreenWipeShortcutTests.swift`
- Delete: `Sources/ToolBox/HotKeyController.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: `ShortcutRegistry.onAction`.
- Produces: screen-wipe `beginIfExitShortcutRegistered()` and an AppDelegate capture-region callback seam for the next plan.

- [ ] **Step 1: Replace old tests with failing migration tests**

Create a fake `ShortcutRegistrationChecking` interface. Assert screen wipe refuses to start when `.screenWipeExit` is not registered and starts when it is. Remove tests that instantiate the deleted single-hot-key controller.

- [ ] **Step 2: Run migration tests to verify RED**

Expected: compile failure until ScreenWipeCoordinator accepts the registration checker.

- [ ] **Step 3: Migrate ownership**

ScreenWipeCoordinator no longer installs or unregisters a hot key. AppDelegate dispatches `.screenWipeExit` to `screenWipe.stop()` and `.captureRegion` to a temporary explicit `onCaptureRegionRequested` closure that logs `not yet installed`; the next plan replaces that seam with `ScreenshotCoordinator.startRegionCapture()`.

Correct README’s false “hold for 1.5 seconds” statement to the actual single-press behavior unless a separate long-press feature is later designed.

- [ ] **Step 4: Run all shortcut tests, full tests and builds**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project ToolBox.xcodeproj -scheme ToolBox -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project ToolBox.xcodeproj -scheme ToolBox -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
git diff --check
```

Expected: all tests pass, both builds succeed, and diff check emits no errors.

- [ ] **Step 5: Perform manual acceptance**

Verify both shortcuts operate concurrently, capture can be disabled/rebound/restored, a conflicting combination retains the old action, the protected wipe binding cannot be disabled, and screen wipe refuses to cover displays if its exit registration is absent.
