# Advanced PaddleOCR Pipelines Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add complete local PP-StructureV3 and PaddleOCR-VL parsing, plus per-screenshot pipeline and model-variant selection.

**Architecture:** Keep PP-OCRv6 in the existing in-process ONNX runtime. Run PP-StructureV3 and PaddleOCR-VL in a bundled, signed Python worker over a versioned JSON-lines protocol; the app owns model selection, verified model leases, timeouts, cancellation, result validation, and editor presentation. Generalize settings and manifests around a pipeline-aware `OCRModelSelection`, and return the existing `OCRResult` sum type from the service boundary.

**Tech Stack:** Swift 5, SwiftUI/AppKit, Foundation `Process`, Python 3, PaddleOCR 3.7.x, MLX-VLM on Apple Silicon, ONNX Runtime, CryptoKit, JSON Lines, XCTest, XcodeGen, macOS 14+.

## Global Constraints

- All inference stays local; no cloud endpoint or remote inference fallback.
- Runtime code ships inside the signed application. Runtime downloads contain only model weights and static resources.
- Preserve PP-OCRv6 Tiny/Small/Medium behavior and migrate existing v1 settings.
- Expose only models supported by the architecture, device class, bundled worker, and signed catalog.
- Use private per-request directories and remove them on success, failure, cancellation, timeout, and app shutdown.
- Treat worker output as untrusted and enforce UTF-8, line, total-size, nesting, polygon, Markdown, and path limits.
- Keep Structure blocks and VL document/Markdown results distinct from text-line OCR.
- Run `xcodegen generate` immediately before each `xcodebuild` after adding files.

---

### Task 1: Generic Model Selection And Settings Migration

**Files:**
- Modify: `Sources/ToolBox/OCR/Models/OCRPipelineModels.swift`
- Modify: `Sources/ToolBox/OCR/OCRSettingsStore.swift`
- Modify: `Sources/ToolBox/OCR/Models/OCRModelManifest.swift`
- Modify: `Tests/ToolBoxTests/OCRSettingsStoreTests.swift`
- Modify: `Tests/ToolBoxTests/OCRModelManifestTests.swift`

**Interfaces:**
- Produces: `OCRModelVariant`, `OCRModelSelection`, `OCRSettings.selection`, schema-v1 migration, and pipeline-aware manifests.

- [ ] Write tests proving defaults are `ppOCRv6/tiny`, v1 JSON migrates without overwrite, v2 round-trips all pipelines, and invalid pipeline/variant pairs are rejected.
- [ ] Run the focused settings/manifest tests and verify they fail because generic selections do not exist.
- [ ] Implement stable `pipeline + variantID` selection, schema v2 decoding/encoding, and legacy `profile` manifest decoding.
- [ ] Re-run the focused tests and verify they pass.

### Task 2: Worker Protocol And Result Projection

**Files:**
- Create: `Sources/ToolBox/OCR/Worker/OCRWorkerProtocol.swift`
- Create: `Sources/ToolBox/OCR/Worker/OCRWorkerResultProjection.swift`
- Create: `Tests/ToolBoxTests/OCRWorkerProtocolTests.swift`
- Create: `Tests/ToolBoxTests/OCRWorkerResultProjectionTests.swift`
- Modify: `Sources/ToolBox/OCR/OCRResult.swift`

**Interfaces:**
- Produces: schema-v1 request/cancel/result/error envelopes and `OCRWorkerResultProjection.project(_:imageSize:) -> OCRResult`.

- [ ] Write literal JSON tests for Structure title/paragraph/image/table/unknown blocks and VL Markdown/source blocks.
- [ ] Add malformed UTF-8, schema, pipeline, polygon, nesting, duplicate task, and 16 MiB Markdown limit cases.
- [ ] Run the focused protocol/projection tests and verify RED.
- [ ] Implement bounded Codable envelopes and projection, rejecting result/pipeline mismatches and invalid normalized geometry.
- [ ] Re-run the focused tests and verify GREEN.

### Task 3: Worker Process Lifecycle And Containment

**Files:**
- Create: `Sources/ToolBox/OCR/Worker/OCRWorkerClient.swift`
- Create: `Sources/ToolBox/OCR/Worker/OCRWorkerExecutableLocator.swift`
- Create: `Tests/ToolBoxTests/OCRWorkerClientTests.swift`
- Modify: `Sources/ToolBox/Screenshot/Editor/ScreenshotPNGExporter.swift`

**Interfaces:**
- Produces: `OCRWorkerRunning.run(source:selection:modelDirectory:) async throws -> OCRResult` and `shutdown()`.

- [ ] Write tests using a temporary protocol-compatible executable for success, one-at-a-time execution, cancellation, timeout, crash/restart, stderr backpressure, oversized output, partial EOF, and cleanup.
- [ ] Run the client tests and verify RED.
- [ ] Implement an actor client that launches only the bundled executable, drains stdout/stderr concurrently, caps lines at 8 MiB and total output at 32 MiB, and validates all paths stay inside a `0700` session directory with `0600` PNG input.
- [ ] Re-run the client tests and verify GREEN with no leaked process or session directory.

### Task 4: Bundled PaddleOCR Worker Runtime

**Files:**
- Create: `Sources/ToolBoxOCRWorker/toolbox_ocr_worker.py`
- Create: `Sources/ToolBoxOCRWorker/projections.py`
- Create: `Tests/OCRWorkerTests/test_worker.py`
- Create: `scripts/bootstrap_ocr_worker_runtime.sh`
- Create: `third_party/ocr-worker/dependencies.lock.json`
- Create: `third_party/ocr-worker/README.md`
- Modify: `project.yml`
- Modify: `THIRD_PARTY_NOTICES.md`

**Interfaces:**
- Produces: bundled `Contents/Helpers/ToolBoxOCRWorker/bin/python3` and worker script speaking schema-v1 JSONL.

- [ ] Write Python tests with complete upstream-shaped fixtures for PP-StructureV3 and PaddleOCR-VL; cover cancellation, missing model directories, malformed output, and networking-disabled construction.
- [ ] Run `python3 -m unittest discover -s Tests/OCRWorkerTests -v` and verify RED.
- [ ] Implement explicit local-model construction, Structure JSON normalization, VL `markdown_texts` normalization, and no embedded image bytes or executable markup.
- [ ] Implement a pinned bootstrap that verifies CPython and every wheel/archive, installs into `.build/ocr-worker-runtime`, removes caches, and rejects files outside an executable allowlist.
- [ ] Re-run Python tests and `./scripts/bootstrap_ocr_worker_runtime.sh --verify-only`.

### Task 5: Pipeline-Aware Catalog And Feature Service

**Files:**
- Modify: `Sources/ToolBox/OCR/OCRFeatureService.swift`
- Modify: `Sources/ToolBox/OCR/Models/OCRModelCatalogLoader.swift`
- Modify: `Resources/OCRModels/catalog-v1.json`
- Modify: `Resources/OCRModels/catalog-v1.sig`
- Modify: `Resources/OCRModels/PaddleOCR-NOTICE.txt`
- Modify: `Tests/ToolBoxTests/OCRFeatureServiceTests.swift`
- Modify: `Tests/ToolBoxTests/OCRModelCatalogLoaderTests.swift`

**Interfaces:**
- Produces: selection-based descriptor/install APIs and `recognize(...) -> OCRResult`.

- [ ] Write failing tests for exact pipeline+variant lookup, provider/version cache keys, PP-OCR routing, Structure/VL worker routing, unavailable variants, consent, leases, cancellation, and no advanced-to-PP-OCR fallback.
- [ ] Run focused service/catalog tests and verify RED.
- [ ] Generalize the service around `OCRModelSelection`; route only PP-OCRv6 in-process and advanced pipelines through the worker while holding their leases.
- [ ] Add immutable model URLs, lengths, SHA-256 values, variant labels, gates, and license resources to the signed catalog; regenerate the signature with the external release key.
- [ ] Re-run focused tests and verify GREEN.

### Task 6: Per-Screenshot Selection And Complete Result UI

**Files:**
- Create: `Sources/ToolBox/OCR/OCRResultViews.swift`
- Modify: `Sources/ToolBox/Screenshot/ScreenshotPreviewView.swift`
- Modify: `Sources/ToolBox/Screenshot/ScreenshotSettingsView.swift`
- Modify: `Tests/ToolBoxTests/OCRFeatureServiceTests.swift`
- Modify: `Tests/ToolBoxTests/ScreenshotOCRSelectionTests.swift`

**Interfaces:**
- Produces: editor-local pipeline/variant selection, Structure block UI, VL Markdown UI, and source-region overlays.

- [ ] Write failing editor-model tests for persisted defaults, valid variant switching, request snapshots, stale-result suppression, type-specific selection state, and correct plain-text/Markdown copying.
- [ ] Run focused editor/OCR tests and verify RED.
- [ ] Replace the single OCR command with a model/variant menu and explicit recognize action; persist valid choices as future defaults.
- [ ] Render text lines, Structure block labels/table summaries, and VL Markdown separately; draw type-specific source polygons without flattening overlays into exported PNGs.
- [ ] Re-run focused tests and verify GREEN.

### Task 7: Documentation, Packaging, And Verification

**Files:**
- Modify: `README.md`
- Modify: `build.sh`
- Modify: `scripts/package-release.sh`
- Modify: `Resources/ToolBox.entitlements`
- Modify: `Resources/ToolBox-AdHoc.entitlements`

- [ ] Document the three pipelines, result types, variants, device gates, local-only behavior, and per-screenshot selection.
- [ ] Make release packaging fail for missing worker runtime, licenses, invalid catalog signatures, bad nested signatures, or absolute loader paths.
- [ ] Run worker tests, full XCTest, Debug/Release builds, `codesign --verify --deep --strict`, offline fixtures for every enabled pipeline, and `git diff --check`.
- [ ] Record any external release-key, dependency-download, notarization, or hardware acceptance checks that cannot run locally.
