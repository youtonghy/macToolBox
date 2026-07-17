# Compact Rounded Menu Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fit the existing menu-panel content into one compact, non-scrolling window and make its glass surface genuinely rounded with transparent exterior corners.

**Architecture:** Add one internal `MenuPanelLayout` namespace as the source of truth for panel geometry shared by SwiftUI and AppKit. Keep `PopoverContent` responsible for content composition, while `GlassContainerView` owns clipping the complete glass surface and `NSPanel` owns the exterior shadow.

**Tech Stack:** Swift 5, SwiftUI, AppKit, Core Animation, XCTest, XcodeGen, macOS 14.

## Global Constraints

- Preserve every currently displayed label, cable detail line, status value, chart, DDC slider, picker, and toggle.
- Keep the existing single-column information order.
- Remove the menu panel's vertical scrolling rather than hiding its indicator.
- Keep the `NSPanel` borderless, non-opaque, and clear.
- Use one continuous rounded clipping boundary for the complete glass surface.
- Let the `NSPanel` provide the exterior shadow; do not render a rectangular container-layer shadow.
- Keep the deployment target at macOS 14.0 and add no third-party dependency.
- Do not change DDC scheduling, transport, value conversion, or readback behavior.
- Do not stage, revert, or rewrite unrelated existing worktree changes.
- Use `CONFIG=Debug OPEN=0 ./build.sh` and `OPEN=0 ./build.sh` for final builds.

## File Map

- Create `Sources/ToolBox/MenuPanelLayout.swift`: shared compact panel geometry and rounded-surface metrics.
- Create `Tests/ToolBoxTests/MenuPanelLayoutTests.swift`: regression checks for compact dimensions.
- Modify `Sources/ToolBox/AppDelegate.swift`: use the shared panel size.
- Modify `Sources/ToolBox/PopoverContent.swift`: remove scrolling and apply compact spacing, padding, chart, cable-row, and controls metrics.
- Modify `Sources/ToolBox/DisplayControl/DisplayControlPanel.swift`: compact the display header and control rows without removing controls.
- Modify `Sources/ToolBox/HardwareData/HardwareMenuViews.swift`: make AppKit chart fitting height match the shared compact height.
- Modify `Sources/ToolBox/HardwareData/HardwareMenuModel.swift`: make cable-height calculation use the shared compact row height.
- Create `Tests/ToolBoxTests/GlassContainerViewTests.swift`: verify the glass root clips and does not own an exterior shadow.
- Modify `Sources/ToolBox/GlassHostingViewController.swift`: clip the entire container and remove its layer shadow.
- Modify `Sources/ToolBox/MenuBarPanelController.swift`: invalidate the system shadow after showing the shaped panel.
- Modify `README.md`: document the compact, non-scrolling rounded panel behavior.

---

### Task 1: Centralize Compact Panel Geometry

**Files:**
- Create: `Sources/ToolBox/MenuPanelLayout.swift`
- Create: `Tests/ToolBoxTests/MenuPanelLayoutTests.swift`
- Modify: `Sources/ToolBox/AppDelegate.swift`

**Interfaces:**
- Produces: `MenuPanelLayout.size: NSSize`
- Produces: `MenuPanelLayout.contentInsets: NSEdgeInsets`
- Produces: compact spacing, padding, height, and corner-radius constants consumed by later tasks.

- [ ] **Step 1: Write the failing geometry test**

Create `Tests/ToolBoxTests/MenuPanelLayoutTests.swift`:

```swift
import XCTest
@testable import ToolBox

final class MenuPanelLayoutTests: XCTestCase {
    func testCompactPanelMetricsFitTheApprovedDesign() {
        XCTAssertEqual(MenuPanelLayout.size.width, 560)
        XCTAssertEqual(MenuPanelLayout.size.height, 640)
        XCTAssertEqual(MenuPanelLayout.contentInsets.top, 14)
        XCTAssertEqual(MenuPanelLayout.chartHeight, 96)
        XCTAssertEqual(MenuPanelLayout.cableRowHeight, 82)
        XCTAssertEqual(MenuPanelLayout.controlsHeight, 50)
        XCTAssertEqual(MenuPanelLayout.cornerRadius, 22)
    }
}
```

- [ ] **Step 2: Verify RED**

Run:

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' -only-testing:ToolBoxTests/MenuPanelLayoutTests
```

Expected: compilation fails because `MenuPanelLayout` does not exist.

- [ ] **Step 3: Implement the shared metrics**

Create `Sources/ToolBox/MenuPanelLayout.swift`:

```swift
import AppKit

enum MenuPanelLayout {
    static let size = NSSize(width: 560, height: 640)
    static let contentInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    static let cornerRadius: CGFloat = 22

    static let outerSpacing: CGFloat = 12
    static let contentSpacing: CGFloat = 10
    static let sectionSpacing: CGFloat = 7
    static let sectionPadding: CGFloat = 10
    static let chartHeight: CGFloat = 96
    static let cableRowHeight: CGFloat = 82
    static let controlsHeight: CGFloat = 50
    static let controlRowSpacing: CGFloat = 6
}
```

Replace the local size in `AppDelegate`:

```swift
private let popoverSize = MenuPanelLayout.size
```

- [ ] **Step 4: Verify GREEN**

Run:

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' -only-testing:ToolBoxTests/MenuPanelLayoutTests
```

Expected: the geometry test passes.

- [ ] **Step 5: Check the task diff**

Run:

```bash
git diff --check -- Sources/ToolBox/MenuPanelLayout.swift Sources/ToolBox/AppDelegate.swift Tests/ToolBoxTests/MenuPanelLayoutTests.swift
```

Expected: no output.

### Task 2: Replace Scrolling with the Compact Single-Column Layout

**Files:**
- Modify: `Sources/ToolBox/PopoverContent.swift`
- Modify: `Sources/ToolBox/DisplayControl/DisplayControlPanel.swift`
- Modify: `Sources/ToolBox/HardwareData/HardwareMenuViews.swift`
- Modify: `Sources/ToolBox/HardwareData/HardwareMenuModel.swift`

**Interfaces:**
- Consumes: all `MenuPanelLayout` metrics from Task 1.
- Preserves: `PopoverContent(state:hardware:displayControl:)` and `DisplayControlPanel(model:)` public call sites.

- [ ] **Step 1: Write the failing standard-content fit test**

Add to `MenuPanelLayoutTests`:

```swift
func testStandardCompleteConfigurationFitsWithoutScrolling() {
    let availableHeight = MenuPanelLayout.size.height
        - MenuPanelLayout.contentInsets.top
        - MenuPanelLayout.contentInsets.bottom

    XCTAssertLessThanOrEqual(MenuPanelLayout.standardContentHeight, availableHeight)
    XCTAssertLessThan(MenuPanelLayout.chartHeight, 126)
    XCTAssertLessThan(MenuPanelLayout.cableRowHeight, 92)
    XCTAssertLessThan(MenuPanelLayout.controlsHeight, 64)
    XCTAssertLessThan(MenuPanelLayout.sectionPadding, 14)
    XCTAssertLessThan(MenuPanelLayout.outerSpacing, 18)
}
```

- [ ] **Step 2: Verify RED**

Run:

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' -only-testing:ToolBoxTests/MenuPanelLayoutTests
```

Expected: compilation fails because `MenuPanelLayout.standardContentHeight` does not exist.

- [ ] **Step 3: Remove the outer scroll view and compact the composition**

First add the standard one-cable, external-display geometry guard to `MenuPanelLayout`:

```swift
static let headerHeight: CGFloat = 44
static let hardwareSectionHeight = chartHeight + 44
static let cableSectionHeight = cableRowHeight + 44
static let displaySectionHeight: CGFloat = 154

static let standardContentHeight = headerHeight
    + outerSpacing
    + hardwareSectionHeight
    + contentSpacing
    + cableSectionHeight
    + contentSpacing
    + displaySectionHeight
    + outerSpacing
    + controlsHeight
```

These values describe the approved common configuration with one active cable and all DDC controls visible. Then change the top-level composition in `PopoverContent.body` to:

```swift
VStack(alignment: .leading, spacing: MenuPanelLayout.outerSpacing) {
    header

    VStack(alignment: .leading, spacing: MenuPanelLayout.contentSpacing) {
        hardwareSection

        if !hardware.cableItems.isEmpty {
            section(title: "线缆状态", subtitle: "当前连接中的 PD / 数据 / 显示链路") {
                CableListView(items: hardware.cableItems)
                    .frame(height: hardware.cableListHeight)
                    .clipped()
            }
        }

        if displayControl.hasExternalDisplay {
            section(title: "显示器控制", subtitle: "DDC / VCP 实时写回外接屏幕") {
                DisplayControlPanel(model: displayControl)
            }
        }
    }

    controlsBar
}
.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
.background(Color.clear)
```

Apply the shared compact metrics to existing views:

```swift
VStack(alignment: .leading, spacing: MenuPanelLayout.sectionSpacing) { ... }
.padding(MenuPanelLayout.sectionPadding)

.frame(height: MenuPanelLayout.chartHeight)

.frame(maxWidth: .infinity, minHeight: MenuPanelLayout.controlsHeight, maxHeight: MenuPanelLayout.controlsHeight)

.frame(maxWidth: .infinity, minHeight: MenuPanelLayout.cableRowHeight, alignment: .topLeading)
```

Tighten, but do not remove, the header badges, cable line spacing, section title spacing, and controls padding so they fit those heights.

- [ ] **Step 4: Compact display controls without changing behavior**

Use `MenuPanelLayout.controlRowSpacing` for the display stack and reduce only its internal whitespace:

```swift
VStack(alignment: .leading, spacing: MenuPanelLayout.controlRowSpacing) {
    // Existing display title, status/picker, and three slider rows remain unchanged.
}
.padding(8)
```

Keep `Slider(value:in:step:)`, picker selection, percent labels, mute button, and bindings unchanged.

- [ ] **Step 5: Align AppKit chart and cable height calculations**

Change `PowerChartRepresentable.sizeThatFits` to return:

```swift
CGSize(width: proposal.width ?? 240, height: MenuPanelLayout.chartHeight)
```

Change `HardwareMenuLayout` to:

```swift
enum HardwareMenuLayout {
    static let maxCableListHeight = MenuPanelLayout.cableRowHeight * 3
}
```

Then calculate cable list height with `MenuPanelLayout.cableRowHeight` and keep all four existing visible detail lines.

- [ ] **Step 6: Verify no scrolling remains and focused tests pass**

Run:

```bash
! rg -n 'ScrollView' Sources/ToolBox/PopoverContent.swift
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' -only-testing:ToolBoxTests/MenuPanelLayoutTests
```

Expected: the search returns no match and all layout tests pass.

### Task 3: Give the Glass Surface One Real Rounded Boundary

**Files:**
- Create: `Tests/ToolBoxTests/GlassContainerViewTests.swift`
- Modify: `Sources/ToolBox/GlassHostingViewController.swift`
- Modify: `Sources/ToolBox/MenuBarPanelController.swift`

**Interfaces:**
- Consumes: `MenuPanelLayout.cornerRadius`.
- Produces: internal `GlassContainerView` whose root layer clips every child surface.
- Preserves: `GlassHostingViewController` and `GlassPopoverViewController` initializers.

- [ ] **Step 1: Write the failing rounded-container test**

Create `Tests/ToolBoxTests/GlassContainerViewTests.swift`:

```swift
import AppKit
import XCTest
@testable import ToolBox

final class GlassContainerViewTests: XCTestCase {
    func testRootLayerOwnsClippingButNotExteriorShadow() throws {
        let view = GlassContainerView(frame: NSRect(origin: .zero, size: MenuPanelLayout.size))
        let layer = try XCTUnwrap(view.layer)

        XCTAssertEqual(layer.cornerRadius, MenuPanelLayout.cornerRadius)
        XCTAssertEqual(layer.cornerCurve, .continuous)
        XCTAssertTrue(layer.masksToBounds)
        XCTAssertEqual(layer.shadowOpacity, 0)
    }
}
```

- [ ] **Step 2: Verify RED**

Run:

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' -only-testing:ToolBoxTests/GlassContainerViewTests
```

Expected: compilation fails because `GlassContainerView` is private, or the mask assertion fails because `masksToBounds` is false.

- [ ] **Step 3: Implement the single rounded clipping boundary**

Make `GlassContainerView` internal for `@testable` access and configure its root layer as:

```swift
final class GlassContainerView: NSView {
    // Existing sublayers and effect views remain.

    private func configureView() {
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = MenuPanelLayout.cornerRadius
        layer?.masksToBounds = true
        layer?.shadowOpacity = 0

        // Keep existing glass effect, tint, border, highlight, and glow setup.
    }
}
```

Replace all hard-coded outer `24` radii in this container with `MenuPanelLayout.cornerRadius`, adjusting inset radii from that shared value. Keep each effect view clipped as a defensive local boundary, but do not add any fill outside the root layer.

- [ ] **Step 4: Refresh the system window shadow after shape changes**

After ordering the panel front in `MenuBarPanelController.show(relativeTo:)`, add:

```swift
panel.invalidateShadow()
```

Retain the existing panel configuration:

```swift
panel.backgroundColor = .clear
panel.isOpaque = false
panel.hasShadow = true
```

- [ ] **Step 5: Verify GREEN**

Run:

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' -only-testing:ToolBoxTests/GlassContainerViewTests
```

Expected: the rounded-container test passes.

### Task 4: Document and Verify the Complete Panel

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: completed compact layout and rounded window behavior.
- Produces: user-facing behavior documentation and final verification evidence.

- [ ] **Step 1: Update nearby menu-interaction documentation**

Extend the existing menu-interaction feature bullet to state that the hardware, cable, display, and tool sections use a compact single-window layout without vertical scrolling, and that the popup uses a genuinely clipped rounded glass surface.

- [ ] **Step 2: Run all unit tests**

Run:

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS'
```

Expected: all `ToolBoxTests` pass with zero failures.

- [ ] **Step 3: Run Debug and Release builds**

Run:

```bash
CONFIG=Debug OPEN=0 ./build.sh
OPEN=0 ./build.sh
```

Expected: both commands end with `** BUILD SUCCEEDED **` and produce Debug and Release app bundles.

- [ ] **Step 4: Check code quality and scope**

Run:

```bash
git diff --check
git diff --stat
git status --short
```

Expected: no whitespace errors; only the intended compact-panel files plus pre-existing user work remain changed.

- [ ] **Step 5: Perform visual verification**

Launch `build/Build/Products/Release/ToolBox.app`, open the menu-bar panel, and inspect it in light and dark appearances.

Expected:

- no vertical scroll gesture or clipped bottom controls;
- all current labels, cable details, chart values, DDC controls, and toggles remain visible;
- content has tighter but readable spacing;
- all four exterior corners are transparent;
- the panel has one natural system shadow and no square background.
