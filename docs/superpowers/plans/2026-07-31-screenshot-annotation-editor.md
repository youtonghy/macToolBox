# Screenshot Annotation Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the temporary screenshot preview with a non-destructive editor that supports shapes, arrows, freehand drawing, highlighter, text, mosaic, numbered markers, undo/redo, PNG copy and Save As.

**Architecture:** `ScreenshotDocument` owns an immutable `ScreenshotImageSource` plus value-type
annotations. Static captures use a `CGImage` source; long captures use a read-only tiled/file-backed
source. A pure reducer manages mutations and history. One banded Core Graphics/Core Image renderer
serves bounded preview tiles, clipboard output and saved PNGs.

**Tech Stack:** Swift 5, AppKit, SwiftUI, CoreGraphics, CoreImage, CoreText, ImageIO, UniformTypeIdentifiers, XCTest, XcodeGen, macOS 14+.

## Global Constraints

- Requires the completed screenshot capture and selection plan.
- Preserve unrelated dirty changes.
- Keep the base image immutable for the document lifetime.
- Store annotation geometry in base-image pixels, never view points.
- Render mosaic from the base image, not from previously rendered output.
- Keep OCR results in a separate document layer; this plan must not invent OCR behavior.
- Clipboard and Save As must use the same PNG exporter as the editor preview.
- Never create a second full-image RGBA context for a tiled/long source; render bounded bands through
  a file-backed export with a 256 MiB resident working-set acceptance limit.
- Reject non-finite geometry, dimension overflow and invalid text/font values with typed errors.
- Use test-first development and do not commit unless separately requested.
- Run `xcodegen generate` immediately before every `xcodebuild` command after adding files.

---

### Task 1: Annotation values, commands and bounded undo history

**Files:**
- Create: `Sources/ToolBox/Screenshot/Editor/ScreenshotDocument.swift`
- Create: `Sources/ToolBox/Screenshot/Editor/ScreenshotImageSource.swift`
- Create: `Sources/ToolBox/Screenshot/Editor/ScreenshotAnnotation.swift`
- Create: `Sources/ToolBox/Screenshot/Editor/AnnotationCommandReducer.swift`
- Create: `Tests/ToolBoxTests/AnnotationCommandReducerTests.swift`

**Interfaces:**
- Produces: `ScreenshotDocument`, `ScreenshotAnnotation`, `AnnotationStyle`, `AnnotationCommand`, `AnnotationEditorState`, `AnnotationCommandReducer.reduce`.
- Consumes: the capture plan's `ScreenshotCaptureMetadata` and immutable
  `CGImageScreenshotSource`.

- [ ] **Step 1: Write failing reducer tests**

```swift
final class AnnotationCommandReducerTests: XCTestCase {
    func testAddUndoRedoPreservesBaseImageIdentity() throws {
        let source = makeImageSource(width: 200, height: 100)
        var state = AnnotationEditorState(document: makeDocument(source: source))
        let annotation = rectangleAnnotation(
            rect: CGRect(x: 10, y: 20, width: 50, height: 30)
        )

        try AnnotationCommandReducer.reduce(state: &state, command: .add(annotation))
        try AnnotationCommandReducer.reduce(state: &state, command: .undo)
        try AnnotationCommandReducer.reduce(state: &state, command: .redo)

        XCTAssertEqual(state.document.baseImage.id, source.id)
        XCTAssertEqual(state.document.annotations, [annotation])
    }
}
```

Add update, delete, reorder, sequential undo/redo, redo invalidation after a new edit, unknown annotation ID, invalid geometry, empty text, invalid style and history-cap eviction cases.

- [ ] **Step 2: Run the focused suite to verify RED**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/AnnotationCommandReducerTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure because editor document and reducer types do not exist.

- [ ] **Step 3: Implement document and command models**

Use explicit annotation payloads rather than a dictionary:

```swift
enum ScreenshotAnnotationPayload: Equatable, Sendable {
    case rectangle(CGRect)
    case ellipse(CGRect)
    case line(start: CGPoint, end: CGPoint)
    case arrow(start: CGPoint, end: CGPoint, headLength: CGFloat)
    case stroke(points: [CGPoint], isHighlighter: Bool)
    case text(TextAnnotation)
    case mosaic(rect: CGRect, blockSize: Int)
    case numberedMarker(center: CGPoint, number: Int)
}
```

Each `ScreenshotAnnotation` has a UUID, payload, style and transform. `ScreenshotImageSource` exposes
immutable pixel dimensions and bounded `copyPixels(in:)`; `CGImageScreenshotSource` is the initial
implementation and the long-capture plan adds the file-backed source. Validate annotations against
source dimensions. Store inverse commands with a default cap of 100; clear redo after a successful
edit. Selection and hover remain transient and never enter the exported document.

- [ ] **Step 4: Run reducer tests to verify GREEN**

Run the Step 2 command. Expected: all reducer tests pass.

### Task 2: Shared renderer, mosaic and PNG exporter

**Files:**
- Create: `Sources/ToolBox/Screenshot/Editor/AnnotationRenderer.swift`
- Create: `Sources/ToolBox/Screenshot/Editor/ScreenshotPNGExporter.swift`
- Create: `Tests/ToolBoxTests/AnnotationRendererTests.swift`
- Add fixtures: `Tests/ToolBoxTests/Fixtures/Screenshot/editor-base.png`
- Add fixtures: `Tests/ToolBoxTests/Fixtures/Screenshot/editor-expected.png`

**Interfaces:**
- Produces: `AnnotationRendering.renderTile(document:pixelRect:scale:)`,
  `ScreenshotExporting.writePNG(document:to:)`.
- Consumes: immutable image and ordered annotations.

- [ ] **Step 1: Write failing pixel and export tests**

Assert rectangle/ellipse bounds, round line caps, arrowhead direction, pen/highlighter alpha, text
baseline, marker number, mosaic sampling, z-order and tile-boundary continuity against fixtures.
Verify PNG dimensions, alpha mode and metadata policy. Add a synthetic 60,000-pixel-tall file-backed
source and an allocation recorder proving no render band exceeds 16 MiB and no full RGBA context is
requested.

- [ ] **Step 2: Run renderer tests to verify RED**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/AnnotationRendererTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure for missing renderer and exporter.

- [ ] **Step 3: Implement one rendering pipeline**

Render an sRGB premultiplied context only for the requested clipped band after checked multiplication;
cap each working band at 16 MiB. Ask the image source only for intersecting pixels, then draw
intersecting annotations. Use CoreText and one shared path builder for preview/export. The canvas keeps
a bounded LRU tile cache rather than a full-image preview.

For mosaic, request the intersecting source pixels, downsample to the requested block grid with
interpolation disabled, then scale back into the same rectangle. Clamp all clips to image bounds and
carry neighboring block origins across tile boundaries.

- [ ] **Step 4: Implement PNG export**

Flatten bands into a private memory-mapped backing file, releasing each band before rendering the
next. Give ImageIO a read-only provider over that backing to encode `UTType.png.identifier`, then
remove the backing file on every exit path. Do not include source paths, OCR text or private capture
metadata. Return typed allocation, disk-space, destination and finalization errors. Stress acceptance
must keep peak resident working set below 256 MiB excluding a separate OCR worker.

- [ ] **Step 5: Run renderer tests to verify GREEN**

Run the Step 2 command. Expected: exact fixture and PNG tests pass.

### Task 3: Canvas coordinate transform and tool interaction

**Files:**
- Create: `Sources/ToolBox/Screenshot/Editor/EditorViewportTransform.swift`
- Create: `Sources/ToolBox/Screenshot/Editor/ScreenshotEditorCanvasView.swift`
- Create: `Sources/ToolBox/Screenshot/Editor/ScreenshotEditorTool.swift`
- Create: `Tests/ToolBoxTests/EditorViewportTransformTests.swift`
- Create: `Tests/ToolBoxTests/ScreenshotEditorInteractionTests.swift`

**Interfaces:**
- Produces: zoom/pan transforms, hit testing, draft annotations and committed `AnnotationCommand` values.
- Consumes: `AnnotationEditorState` and AppKit mouse/key events.

- [ ] **Step 1: Write failing transform and interaction tests**

Cover pixel-to-view round trips at 25%, 100% and 800% zoom; Retina backing scale independence; fit-to-window; clamped zoom; pan bounds; drag normalization in every direction; freehand point simplification; text commit/cancel; mosaic size; marker auto-number; delete; Command-Z and Command-Shift-Z.

- [ ] **Step 2: Run focused tests to verify RED**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/EditorViewportTransformTests \
  -only-testing:ToolBoxTests/ScreenshotEditorInteractionTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure for missing viewport and interaction types.

- [ ] **Step 3: Implement coordinate and gesture handling**

`EditorViewportTransform` is a pure affine mapping. The AppKit canvas converts every incoming point to image pixels before creating a draft. Mouse-up commits one command; Escape discards the draft. Pen/highlighter collect points and simplify them deterministically without changing first/last points.

Text editing uses a temporary `NSTextView` positioned from the same transform. Commit non-empty text on Command-Return or focus completion; Escape cancels. Keep dynamic text editing out of the document until commit.

- [ ] **Step 4: Run interaction tests to verify GREEN**

Run the Step 2 command. Expected: all transform and interaction tests pass.

### Task 4: Editor window, complete controls and capture integration

**Files:**
- Create: `Sources/ToolBox/Screenshot/Editor/ScreenshotEditorViewModel.swift`
- Create: `Sources/ToolBox/Screenshot/Editor/ScreenshotEditorView.swift`
- Create: `Sources/ToolBox/Screenshot/Editor/ScreenshotEditorWindowController.swift`
- Create: `Tests/ToolBoxTests/ScreenshotEditorViewModelTests.swift`
- Modify: `Sources/ToolBox/Screenshot/ScreenshotCoordinator.swift`
- Modify: `Sources/ToolBox/Screenshot/ScreenshotSettingsView.swift`
- Delete: `Sources/ToolBox/Screenshot/ScreenshotPreviewView.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: the capture coordinator's base image and metadata.
- Produces: editor lifecycle, annotation commands, copy, Save As, close confirmation and a future OCR action seam.

- [ ] **Step 1: Write failing view-model lifecycle tests**

Test tool switching, style persistence, undo/redo availability, unsaved-close confirmation, copy success/failure, Save As cancellation/success, double export suppression, export cancellation and reopening an active editor.

- [ ] **Step 2: Run view-model tests to verify RED**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/ScreenshotEditorViewModelTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure for missing editor view model.

- [ ] **Step 3: Build the editor surface**

Use icon buttons with tooltips for selection, rectangle, ellipse, arrow, line, pen, highlighter, text, mosaic, marker, undo, redo, copy and save. Use swatches for color, a segmented control for stroke presets, and a numeric control for text size/mosaic block size. Keep toolbar geometry stable as controls change.

Expose explicit idle, editing-text, exporting, failed and close-confirmation states. Show errors in the editor and allow retry; do not discard the current document.

- [ ] **Step 4: Replace the temporary preview**

The coordinator creates one `ScreenshotDocument` and presents one editor window. Repeated screenshot shortcut while editing brings the editor forward. Closing resets coordinator state only after export completes or cancellation is confirmed.

Add working screenshot settings for default post-capture behavior (`openEditor`, `copyPNG`, `savePNG`) and remember the last annotation style. Do not add OCR or long-capture settings until those implementations land.

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

- [ ] **Step 6: Complete manual acceptance**

Verify every tool at multiple zoom levels, text input with Chinese/English/Japanese, undo/redo across all tools, export parity with the preview, clipboard paste into Preview and Messages, Save As cancellation, unsaved-close handling, a 60,000-pixel-tall synthetic image and VoiceOver labels for every toolbar control.
