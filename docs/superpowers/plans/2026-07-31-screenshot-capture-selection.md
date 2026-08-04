# Screenshot Capture and Shift Multi-Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a usable region-screenshot workflow with ScreenCaptureKit frozen frames, multi-display geometry, manual/AX/window candidates, and approved Shift-click multi-element expansion.

**Architecture:** A main-actor coordinator orchestrates an injected capture provider, permission service and overlay manager. Candidate resolution and selection changes are pure reducers; platform-specific ScreenCaptureKit and AX objects never escape their providers.

**Tech Stack:** Swift 5, ScreenCaptureKit, AppKit, ApplicationServices, CoreGraphics, UniformTypeIdentifiers, SwiftUI, XCTest, XcodeGen, macOS 14+.

## Global Constraints

- Requires the completed unified shortcut registry plan.
- Preserve unrelated dirty changes.
- Capture all display frames before showing overlays.
- Store selection geometry in global logical points; convert to pixels only at crop boundaries.
- Never retain `AXUIElement` in selection state.
- Shift-click toggles candidates; final output is one union rectangle with real gaps.
- Default output is an editor handoff; until the editor plan lands, show a minimal preview with Copy and Save.
- Use test-first development and explicit typed errors.
- Run `xcodegen generate` immediately before every `xcodebuild` command after adding files.
- Do not commit unless separately requested.

---

### Task 1: Screen-capture permission and pure display geometry

**Files:**
- Create: `Sources/ToolBox/Screenshot/Capture/ScreenCapturePermission.swift`
- Create: `Sources/ToolBox/Screenshot/Capture/CaptureGeometry.swift`
- Create: `Tests/ToolBoxTests/CaptureGeometryTests.swift`
- Modify: `Sources/ToolBox/Permissions.swift`

**Interfaces:**
- Produces: `ScreenCapturePermissionState`, `ScreenCapturePermissionProviding`, `DisplayCaptureGeometry`, `CaptureGeometry.fragments(selection:displays:)`.
- Consumes: global point rectangles and per-display point/pixel metadata.

- [ ] **Step 1: Write failing cross-display geometry tests**

```swift
final class CaptureGeometryTests: XCTestCase {
    func testSelectionAcrossMixedScaleDisplaysProducesPixelFragments() throws {
        let displays = [
            DisplayCaptureGeometry(
                displayID: 1,
                globalFramePoints: CGRect(x: 0, y: 0, width: 1000, height: 800),
                pixelSize: CGSize(width: 2000, height: 1600)
            ),
            DisplayCaptureGeometry(
                displayID: 2,
                globalFramePoints: CGRect(x: 1000, y: 0, width: 800, height: 600),
                pixelSize: CGSize(width: 800, height: 600)
            ),
        ]

        let fragments = try CaptureGeometry.fragments(
            selection: CGRect(x: 900, y: 100, width: 300, height: 200),
            displays: displays
        )

        XCTAssertEqual(fragments.map(\.displayID), [1, 2])
        XCTAssertEqual(fragments[0].sourcePixels.width, 200)
        XCTAssertEqual(fragments[1].sourcePixels.width, 200)
    }
}
```

Add negative-X, display-above-primary, empty, non-finite, no-intersection, fractional point and stable fragment-order cases.

- [ ] **Step 2: Run tests to verify RED**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/CaptureGeometryTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure for missing capture geometry types.

- [ ] **Step 3: Implement geometry and permission adapters**

Use point-to-pixel ratios from `pixelSize / globalFramePoints.size`; do not read `NSScreen.backingScaleFactor` inside pure geometry. Round source pixel minima down and maxima up, then clamp to image bounds.

Extend Permissions with screen-capture preflight, request and Privacy pane navigation. Request only from a user-triggered capture action.

- [ ] **Step 4: Run focused tests to verify GREEN**

Run Step 2. Expected: all geometry tests pass.

### Task 2: ScreenCaptureKit frozen-frame provider and compositor

**Files:**
- Create: `Sources/ToolBox/Screenshot/Capture/ScreenCaptureProvider.swift`
- Create: `Sources/ToolBox/Screenshot/Capture/ScreenshotImageComposer.swift`
- Create: `Sources/ToolBox/Screenshot/Capture/FrozenCaptureBudget.swift`
- Create: `Tests/ToolBoxTests/ScreenshotImageComposerTests.swift`
- Create: `Tests/ToolBoxTests/FrozenCaptureBudgetTests.swift`
- Add fixtures: `Tests/ToolBoxTests/Fixtures/Screenshot/red-2x.png`
- Add fixtures: `Tests/ToolBoxTests/Fixtures/Screenshot/blue-1x.png`

**Interfaces:**
- Produces: `DisplayCaptureFrame`, `ScreenCaptureProviding.captureDisplays() async throws`, `ScreenshotImageComposer.compose(selection:frames:)`.
- Consumes: ScreenCaptureKit `SCShareableContent`, `SCDisplay`, `SCRunningApplication`, `SCContentFilter`, `SCStreamConfiguration`.

- [ ] **Step 1: Write failing compositor pixel tests**

Load the red 2x and blue 1x fixture frames using the Task 1 geometry. Compose a cross-display
selection and assert output dimensions at the maximum intersecting display scale, sample pixels,
1x-to-2x logical-size mapping, sRGB conversion and gap behavior. Add aggregate-byte tests around the
768 MiB frozen-frame limit and integer overflow.

- [ ] **Step 2: Run focused tests to verify RED**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/ScreenshotImageComposerTests \
  -only-testing:ToolBoxTests/FrozenCaptureBudgetTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure for missing composer.

- [ ] **Step 3: Implement the compositor**

Choose the canonical output scale as the maximum `pixelSize / globalFramePoints.size` among
intersecting displays. Create one sRGB bitmap context sized from `selection * outputScale`, then draw
each source-scale crop into its logical destination. Reject dimension overflow, unavailable color
conversion and aggregate frozen-frame estimates above 768 MiB with `ScreenshotCaptureError`.

- [ ] **Step 4: Implement the live provider**

For each online `SCDisplay`, build a display filter excluding the ToolBox `SCRunningApplication`. Set `showsCursor = false`, `width/height` to native pixels and use `SCScreenshotManager.captureImage`. Capture displays serially first for correctness; expose elapsed time diagnostics so parallelization can be evaluated later.

Return no partial success: if topology changes or any required display fails, discard the set and
return a typed retryable error. Release every frozen frame immediately after composition or
cancellation; never retain the display set while the editor is open.

- [ ] **Step 5: Run compositor tests and Debug build**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/ScreenshotImageComposerTests \
  -only-testing:ToolBoxTests/FrozenCaptureBudgetTests CODE_SIGNING_ALLOWED=NO
xcodebuild build -project ToolBox.xcodeproj -scheme ToolBox -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: tests and build pass.

### Task 3: Pure candidate identity and selection reducer

**Files:**
- Create: `Sources/ToolBox/Screenshot/Selection/SelectionModels.swift`
- Create: `Sources/ToolBox/Screenshot/Selection/SelectionReducer.swift`
- Create: `Tests/ToolBoxTests/SelectionReducerTests.swift`

**Interfaces:**
- Produces: `SelectionCandidate`, `SelectedRegionSnapshot`, `SelectionSessionState`, `SelectionAction`, `SelectionReducer.reduce`.
- Consumes: validated global point rectangles.

- [ ] **Step 1: Write failing Shift-selection tests**

```swift
final class SelectionReducerTests: XCTestCase {
    func testShiftClickAddsAndExpandsToUnion() throws {
        var state = SelectionSessionState.empty
        let left = candidate(id: "left", rect: .init(x: 10, y: 10, width: 40, height: 20))
        let right = candidate(id: "right", rect: .init(x: 90, y: 20, width: 30, height: 20))

        try SelectionReducer.reduce(state: &state, action: .click(left, additive: false))
        try SelectionReducer.reduce(state: &state, action: .click(right, additive: true))

        XCTAssertEqual(state.selectedRegions.map(\.candidateKey), ["left", "right"])
        XCTAssertEqual(state.captureBounds, CGRect(x: 10, y: 10, width: 110, height: 30))
    }

    func testShiftClickSelectedCandidateRemovesIt() throws {
        var state = stateSelecting(["left", "right"])
        try SelectionReducer.reduce(
            state: &state,
            action: .click(candidate(id: "left"), additive: true)
        )
        XCTAssertEqual(state.selectedRegions.map(\.candidateKey), ["right"])
    }
}
```

Add normal-click replacement, non-adjacent gap preservation, Delete last, undo, empty confirmation rejection, manual drag clearing element selection, invalid rect rejection and stable insertion order.

- [ ] **Step 2: Run tests to verify RED**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/SelectionReducerTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure for missing selection types.

- [ ] **Step 3: Implement the reducer**

Use an ordered `[SelectedRegionSnapshot]` and a private undo stack of complete value states. Preserve
owner PID, ScreenCaptureKit window ID, display ID and topology generation in every snapshot. A
candidate key combines provider identity, PID, window ID, role, hierarchy index and a rect quantized
to quarter points. Recompute `captureBounds` after every mutation.

- [ ] **Step 4: Run tests to verify GREEN**

Run Step 2. Expected: all reducer tests pass.

### Task 4: Window and AX candidate providers

**Files:**
- Create: `Sources/ToolBox/Screenshot/Selection/WindowRegionProvider.swift`
- Create: `Sources/ToolBox/Screenshot/Selection/AXRegionProvider.swift`
- Create: `Tests/ToolBoxTests/AXRegionProjectionTests.swift`

**Interfaces:**
- Produces: async `region(at:generation:)` and parent-chain snapshots.
- Consumes: cursor position, current shareable windows and injected AX function table.

- [ ] **Step 1: Write failing AX projection tests**

Use an injected AX recorder to return a child button, parent group and window with top-left coordinates. Assert AppKit conversion, zero-area filtering, own-PID filtering, parent ordering, timeout error classification and stale-generation suppression.

- [ ] **Step 2: Run tests to verify RED**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/AXRegionProjectionTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure for missing providers.

- [ ] **Step 3: Implement provider boundaries**

AX work runs on one serial queue with `AXUIElementSetMessagingTimeout`. Convert every AX object
immediately into a value snapshot; release the AX reference before returning. Resolve the containing
`SCWindow` and persist its window ID with the current display/topology generation.
`WindowRegionProvider` ignores ToolBox and off-screen/empty windows and returns the topmost match.

- [ ] **Step 4: Run provider and reducer tests**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/AXRegionProjectionTests \
  -only-testing:ToolBoxTests/SelectionReducerTests CODE_SIGNING_ALLOWED=NO
```

Expected: both suites pass.

### Task 5: Multi-display selection overlays

**Files:**
- Create: `Sources/ToolBox/Screenshot/Selection/ScreenshotSelectionView.swift`
- Create: `Sources/ToolBox/Screenshot/Selection/ScreenshotSelectionOverlayManager.swift`
- Create: `Tests/ToolBoxTests/ScreenshotSelectionOverlayTests.swift`

**Interfaces:**
- Consumes: frozen `DisplayCaptureFrame` values and `SelectionSessionState`.
- Produces: mouse/key actions and `confirm/cancel` callbacks.

- [ ] **Step 1: Write failing overlay lifecycle tests**

With animation disabled and synthetic frames, assert one panel per display, only the interaction panel
can become key, no panel can become main, key ownership follows cross-display interaction, cancel
restores the previous frontmost app, close is idempotent and state changes do not resize panels.

- [ ] **Step 2: Run tests to verify RED**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/ScreenshotSelectionOverlayTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure for missing overlay manager.

- [ ] **Step 3: Implement AppKit panels and interaction**

Use borderless full-screen panels that join all Spaces. Activate ToolBox for selection; make only the
panel receiving interaction key-capable while every panel remains non-main. Transfer key ownership
when interaction begins on another display. Draw the frozen frame, dim layer, element outlines and
union bounds, and convert click modifiers to `.click(candidate, additive: shift)`.

Handle Escape, Delete, Command-Z and Return through the key panel's responder chain; do not install a
global key monitor. Double-click confirms only when `captureBounds` exists. Manual drag emits
`.setManualRegion`. Cancel restores the previously frontmost app; confirm keeps ToolBox active.

- [ ] **Step 4: Run overlay tests and build**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/ScreenshotSelectionOverlayTests CODE_SIGNING_ALLOWED=NO
xcodebuild build -project ToolBox.xcodeproj -scheme ToolBox -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: tests and Debug build pass without requiring Screen Recording.

### Task 6: Coordinator, minimal preview, settings and AppDelegate integration

**Files:**
- Create: `Sources/ToolBox/Screenshot/ScreenshotCoordinator.swift`
- Create: `Sources/ToolBox/Screenshot/ScreenshotModels.swift`
- Create: `Sources/ToolBox/Screenshot/ScreenshotPreviewView.swift`
- Create: `Sources/ToolBox/Screenshot/ScreenshotSettingsView.swift`
- Create: `Tests/ToolBoxTests/ScreenshotCoordinatorTests.swift`
- Modify: `Sources/ToolBox/AppDelegate.swift`
- Modify: `Sources/ToolBox/SettingsView.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: shortcut `.captureRegion`, permission, capture provider, candidate providers, overlay manager and composer.
- Produces: `startRegionCapture()`, `cancel()`, `state`, and an editor handoff closure.

- [ ] **Step 1: Write failing coordinator tests**

Cover no-permission refusal without overlays, successful `idle -> preparing -> selecting`, capture
budget refusal, error cleanup, stale candidate cancellation, confirm composition/frozen-frame release,
Escape cleanup/frontmost-app restoration, repeated shortcut while active and stop idempotency.

- [ ] **Step 2: Run tests to verify RED**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/ScreenshotCoordinatorTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure for missing coordinator.

- [ ] **Step 3: Implement the state machine**

All public methods run on the main actor. Starting while non-idle brings the current selection/editor forward instead of creating a second session. Every async capture/candidate task stores a generation and checks it before applying results.

Until the annotation-editor plan lands, `ScreenshotPreviewView` displays the image with Copy, Save and Close. Save uses `NSSavePanel` and ImageIO PNG encoding; Copy writes PNG/TIFF representations to NSPasteboard and reports errors visibly.

- [ ] **Step 4: Add the Screenshot settings page**

Add a `截图` tab with current Screen Recording and Accessibility status, “显示智能元素候选” default-on toggle and permission actions. Reserve no fake controls for OCR or long capture; their plans add those sections when functional.

- [ ] **Step 5: Wire lifecycle and run full verification**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project ToolBox.xcodeproj -scheme ToolBox -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project ToolBox.xcodeproj -scheme ToolBox -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
git diff --check
```

Expected: full tests and builds pass with no diff errors.

- [ ] **Step 6: Complete manual acceptance**

Test permission denial/grant, one and multiple displays, negative origins, mixed scales, AX and no-AX applications, Shift add/remove with distant elements, manual drag reset, undo/Delete/Return/Escape, PNG copy/save and repeated shortcut behavior.
