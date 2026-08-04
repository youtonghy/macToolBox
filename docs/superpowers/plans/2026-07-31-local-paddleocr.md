# Local PaddleOCR Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add fully local OCR with PP-OCRv6 tiny/small/medium (tiny by default), plus optional PP-StructureV3 and PaddleOCR-VL pipelines, on-demand verified model installation and editor result layers.

**Architecture:** PP-OCRv6 runs in-process through a narrow Swift to Objective-C++ to ONNX Runtime bridge. PP-StructureV3 and PaddleOCR-VL run in a signed, bundled, single-concurrency helper process using a versioned JSON-lines protocol. Runtime code ships with the application; only signed-manifest model weights and static dictionaries may be downloaded.

**Tech Stack:** Swift 5, Objective-C++, C++17, ONNX Runtime CPU/Core ML execution providers, CryptoKit, URLSession, Process, JSON Lines, XCTest, XcodeGen, macOS 14+, PaddleOCR v3.7.0 release artifacts and Apache-2.0 license.

## Global Constraints

- Requires the completed screenshot annotation editor plan.
- Preserve unrelated dirty changes.
- All inference stays on the Mac; there is no cloud API or cloud fallback.
- PP-OCRv6 tiny is selected by default but still requires explicit first-download consent.
- PP-OCRv6 tiny does not support Japanese; the UI must require small or medium for Japanese.
- Model downloads contain weights and static resources only. Never download Python, dylibs, executables, scripts or packages at runtime.
- Accept model artifacts only from immutable HTTPS release URLs listed in the signed application manifest.
- Do not log image bytes, file paths containing user data, OCR text or document Markdown.
- Keep text, structured-layout and document-parse result schemas distinct.
- A pipeline appears only when its packaged runtime supports the current CPU architecture/device
  class. Advanced pipelines additionally require ARM64 hardened-runtime and Developer ID gates.
- Use test-first development, typed errors and cancellation; do not commit unless separately requested.
- Run `xcodegen generate` immediately before every `xcodebuild` command after adding files.

## Upstream references

- PaddleOCR local inference engines: <https://www.paddleocr.ai/latest/en/version3.x/inference_deployment/local_inference/inference_engine.html>
- PP-OCRv6 models: <https://www.paddleocr.ai/latest/en/version3.x/algorithm/PP-OCRv6/PP-OCRv6.html>
- Official iOS ONNX Runtime deployment pattern: <https://www.paddleocr.ai/latest/en/version3.x/inference_deployment/cross_platform/ios_deployment.html>
- PaddleOCR source and license: <https://github.com/PaddlePaddle/PaddleOCR>

---

### Task 1: Pin dependencies and pass the local-runtime architecture gates

**Files:**
- Create: `third_party/ocr/dependencies.lock.json`
- Create: `third_party/ocr/README.md`
- Create: `third_party/ocr/sbom.cdx.json`
- Create: `scripts/ocr/fetch-runtime-dependencies.sh`
- Create: `scripts/ocr/run-architecture-gates.sh`
- Create: `Prototypes/OCRRuntimeGate/README.md`
- Create: `Prototypes/OCRRuntimeGate/ppocrv6/`
- Create: `Prototypes/OCRRuntimeGate/advanced-worker/`
- Modify: `.gitignore`
- Modify: `THIRD_PARTY_NOTICES.md`

**Produces:** reproducible runtime inputs and machine-readable gate reports under `.build/ocr-gates/`.

- [ ] **Step 1: Create a failing dependency-integrity check**

`dependencies.lock.json` records PaddleOCR `v3.7.0` and commit `b03f464`, the selected ONNX Runtime release, embedded worker-runtime distribution, archive URLs, SHA-256 values, unpacked file allowlists and license files. Generate a CycloneDX SBOM and update third-party notices for PaddleOCR, PaddlePaddle/PaddleX, ONNX Runtime, OpenCV, the embedded Python runtime and every transitive binary package. `fetch-runtime-dependencies.sh --verify-only` must fail when any URL is mutable, checksum is missing, a file is outside the allowlist or a license is absent.

```bash
scripts/ocr/fetch-runtime-dependencies.sh --verify-only
```

Expected: failure until every runtime artifact is pinned and verified.

- [ ] **Step 2: Build the PP-OCRv6 architecture prototypes**

Use the official PaddleOCR ONNX export/deployment path and ONNX Runtime C API. Run the full gate on
ARM64. If the application still ships x86_64, either package and gate the same native pipeline on an
Intel Mac or record PP-OCRv6 as unavailable on x86_64; never let Rosetta/loader failure be the runtime
decision. Record provider assignment, cold/warm latency, peak resident memory and output hashes.

The gate passes only when:

- the prototype runs with networking disabled;
- CPU inference works as the production baseline;
- Core ML can be selected explicitly and unsupported nodes fall back to CPU;
- the build contains no XNNPACK EP because ONNX Runtime does not support it on macOS;
- unsupported Core ML operators fall back without corrupting output;
- cancellation releases the session and input buffers;
- compared with PaddleOCR v3.7.0 `engine="onnxruntime"` on the same models, character-error-rate
  difference is at most 0.2 percentage points, detection Hmean difference is at most 0.5 percentage
  points and exact line-text agreement is at least 99.5%;
- on 2560x1600 warm inputs, tiny p50/p95 is at most 0.75/1.5 seconds, small at most 2/4 seconds and
  medium at most 7/12 seconds on the recorded M1 8 GB baseline;
- main-thread blocking remains below 16 ms and cancellation is acknowledged within 250 ms.

- [ ] **Step 3: Build the advanced-worker ARM64 prototype**

Bundle the chosen local PaddleOCR worker runtime and all executable dependencies inside the prototype at build time. Run one PP-StructureV3 fixture and one PaddleOCR-VL fixture through JSON-lines stdin/stdout. Sign every executable and dylib with the same identity, enable hardened runtime and verify there are no absolute development-machine paths.

The gate passes only when:

- `codesign --verify --deep --strict` succeeds;
- an archive passes `notarytool` submission in the release-signing environment;
- network-denied inference succeeds using installed model fixtures;
- cancel completes within two seconds or terminates the worker;
- crash recovery successfully processes the next task;
- cold start, one-image latency and peak memory are written to the gate report.

Run the full PaddleOCR-VL gate on M4 and at least one M1-class machine. Mark each architecture/device
class independently in the shipped availability matrix; official upstream validation on M4 is not
evidence that M1/M2/M3 satisfy the same memory or performance bounds.

- [ ] **Step 4: Enforce the gate result**

```bash
scripts/ocr/run-architecture-gates.sh --configuration Release
```

Expected: a non-zero exit if any pipeline gate fails. PP-OCRv6 implementation may proceed after its gate passes. Task 5 or Task 6 may proceed only for the corresponding advanced pipeline whose signed-worker gate passes; a failed pipeline remains absent from production settings and is reported as an unresolved release blocker rather than stubbed.
The report emits a checked-in availability matrix for `arm64`, `x86_64` and gated Apple Silicon device
classes; settings and the model catalog consume that matrix.

### Task 2: Secure model manifests, installation and leases

**Files:**
- Create: `Sources/ToolBox/OCR/Models/OCRPipelineModels.swift`
- Create: `Sources/ToolBox/OCR/Models/OCRModelManifest.swift`
- Create: `Sources/ToolBox/OCR/Models/OCRModelCatalog.swift`
- Create: `Sources/ToolBox/OCR/Models/OCRModelStore.swift`
- Create: `Sources/ToolBox/OCR/Models/OCRModelDownloadManager.swift`
- Create: `Resources/OCRModels/catalog-v1.json`
- Create: `Resources/OCRModels/catalog-v1.sig`
- Create: `Resources/OCRModels/licenses/`
- Create: `scripts/ocr/prepare-model-release.sh`
- Create: `Tests/ToolBoxTests/OCRModelManifestTests.swift`
- Create: `Tests/ToolBoxTests/OCRModelStoreTests.swift`
- Create: `Tests/ToolBoxTests/OCRModelDownloadManagerTests.swift`
- Create: `Tests/ToolBoxTests/OCRModelBundleTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Produces: `OCRPipelineID`, `PPOCRv6Profile`, `OCRModelManifest`, `OCRModelState`, `OCRModelStore`, `OCRModelLease`.
- Consumes: injected Application Support root, staging root, URLSession and filesystem operations.

- [ ] **Step 1: Write failing manifest and hostile-archive tests**

Cover unknown schema, duplicate IDs, unsupported URL scheme, mutable URL, missing/incorrect archive or per-file hash, length mismatch, missing required files, unsupported architecture/runtime/opset, absolute paths, `..`, Unicode path normalization collisions, symlink/hardlink escape, device files, decompression bombs, installed-size overflow, existing-good-version preservation and deletion while leased.
Also assert the built test host can load `OCRModels/catalog-v1.json`, `catalog-v1.sig` and every
declared license from the exact bundle subdirectory, and that signature verification succeeds.

- [ ] **Step 2: Run model tests to verify RED**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/OCRModelManifestTests \
  -only-testing:ToolBoxTests/OCRModelStoreTests \
  -only-testing:ToolBoxTests/OCRModelDownloadManagerTests \
  -only-testing:ToolBoxTests/OCRModelBundleTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure for missing OCR model types.

- [ ] **Step 3: Implement manifest generation and shipped catalog**

`prepare-model-release.sh` fetches the pinned upstream artifacts, performs any release-time ONNX conversion, removes executable content, generates an allowlisted archive, computes compressed/uncompressed sizes and SHA-256, and emits immutable release assets plus `catalog-v1.json`. Sign the canonical catalog bytes with the release model-signing key; the application contains only the verification public key and rejects a missing or invalid `catalog-v1.sig`.

Catalog entries cover each required component of:

- `ppocrv6-tiny`, `ppocrv6-small`, `ppocrv6-medium`;
- `ppstructure-v3`;
- `paddleocr-vl`.

Each entry records every file's relative path, byte count and SHA-256 plus supported architectures,
languages, PaddleOCR revision, ONNX opset and input/output contract. The catalog is copied into the
signed app bundle. Runtime never accepts a remotely replaced catalog.

Update `project.yml` with a resources entry that copies `Resources/OCRModels` into
`ToolBox.app/Contents/Resources/OCRModels`. Load it only through `Bundle` resource URLs and fail
startup of OCR services when catalog/signature/license resources are absent or invalid.

- [ ] **Step 4: Implement transactional installation**

Download only after explicit user confirmation into a random sibling staging directory. Validate HTTP status, exact compressed length and SHA-256 before extraction. Extract entries through a structured archive API with path and type validation, enforce per-entry and total installed-byte caps, verify required files, fsync, then atomically rename the complete version directory.

State is exactly `notInstalled`, `downloading(progress)`, `validating`, `ready`, `corrupt`, `updateAvailable` or `failed(issue)`. An `OCRModelLease` pins a verified version for a running task; deletion fails visibly while any lease exists. On launch, clean abandoned staging directories but never delete a valid installed version.

- [ ] **Step 5: Run model tests to verify GREEN**

Run the Step 2 command. Expected: all manifest, store and download tests pass.

### Task 3: In-process PP-OCRv6 tiny/small/medium

**Files:**
- Create: `Sources/ToolBox/OCRRuntime/ToolBoxOCRRuntime.h`
- Create: `Sources/ToolBox/OCRRuntime/ToolBoxOCRRuntime.mm`
- Create: `Sources/ToolBox/OCRRuntime/PPOCRv6Pipeline.hpp`
- Create: `Sources/ToolBox/OCRRuntime/PPOCRv6Pipeline.cpp`
- Create: `Sources/ToolBox/OCR/PPOCRv6Service.swift`
- Create: `Sources/ToolBox/OCR/OCRResult.swift`
- Create: `Sources/ToolBox/OCR/TextOCRDocument.swift`
- Create: `Tests/ToolBoxTests/PPOCRv6ServiceTests.swift`
- Create: `Tests/ToolBoxTests/OCRResultProjectionTests.swift`
- Add fixtures: `Tests/ToolBoxTests/Fixtures/OCR/ppocrv6-mixed.png`
- Add fixtures: `Tests/ToolBoxTests/Fixtures/OCR/ppocrv6-mixed-expected.json`
- Modify: `Sources/ToolBox/DisplayControl/Darwin/DisplayControlBridgingHeader.h`
- Modify: `project.yml`

**Interfaces:**
- Produces: the shared `OCRResult` enum, `LocalOCRServicing.recognize(image:pipeline:)`,
  `TextOCRDocument`, and text lines with polygon/confidence/reading order.
- Consumes: a verified model lease and copied pixel buffer.

- [ ] **Step 1: Write failing service and projection tests**

Use an injected C-bridge function table for unit tests. Assert tiny/small/medium model selection, tiny Japanese rejection, missing/corrupt model errors, cancellation, CPU baseline/Core ML opt-in, zero-copy lifetime boundaries, malformed bridge output rejection, normalized polygon projection and reading-order stability.

- [ ] **Step 2: Run PP-OCRv6 tests to verify RED**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/PPOCRv6ServiceTests \
  -only-testing:ToolBoxTests/OCRResultProjectionTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile or link failure until the bridge and runtime are integrated.

- [ ] **Step 3: Implement the narrow native bridge**

Expose opaque session handles and plain C structs from `ToolBoxOCRRuntime.h`; do not expose ONNX Runtime headers to Swift. The bridge copies or explicitly retains the input pixel buffer for the full inference call and owns all returned allocations until one documented destroy call.

Preprocessing, detector postprocessing, perspective crop, recognition decoding and reading-order projection live below the SwiftUI layer. Build one session per installed model version, serialize use per session and close it when its lease is released.

- [ ] **Step 4: Configure runtime packaging**

Update `project.yml` to link the verified ONNX Runtime XCFramework produced by Task 1, include its license and make Release builds fail if its recorded SHA differs. Use CPU as the production baseline. Enable Core ML only when the gate proves output parity and at least a 20% warm-P95 improvement on both M1 and M4 without more than 20% cold-start or RSS regression. Capture provider assignment with ORT profiling without logging content.

- [ ] **Step 5: Run fixture, full test and build verification**

```bash
scripts/ocr/fetch-runtime-dependencies.sh --verify-only
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/PPOCRv6ServiceTests \
  -only-testing:ToolBoxTests/OCRResultProjectionTests CODE_SIGNING_ALLOWED=NO
xcodebuild build -project ToolBox.xcodeproj -scheme ToolBox -configuration Release \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: the fixture meets the checked-in text, polygon and confidence tolerances; tests and Release build pass.

### Task 4: Signed worker protocol, lifecycle and containment

**Files:**
- Create: `Sources/ToolBox/OCRWorker/OCRWorkerProtocol.swift`
- Create: `Sources/ToolBox/OCRWorker/OCRWorkerClient.swift`
- Create: `Sources/ToolBoxOCRWorker/main.swift`
- Create: `Sources/ToolBoxOCRWorker/OCRWorkerServer.swift`
- Create: `Sources/ToolBoxOCRWorker/OCRWorkerRuntimeAdapter.swift`
- Create: `Tests/ToolBoxTests/OCRWorkerProtocolTests.swift`
- Create: `Tests/ToolBoxTests/OCRWorkerClientTests.swift`
- Create: `Tests/ToolBoxOCRWorkerTests/OCRWorkerServerTests.swift`
- Modify: `project.yml`
- Modify: `Resources/ToolBox.entitlements`

**Interfaces:**
- Produces: schema-v1 request/result/cancel envelopes and `OCRWorkerClient.run`.
- Consumes: one input image path in a private session directory and one verified model directory.

- [ ] **Step 1: Write failing protocol and process tests**

Cover unknown schema/pipeline, duplicate task ID, oversized line, invalid UTF-8, output path escape, timeout, cancellation, worker crash, stderr backpressure, partial line at EOF, idle shutdown and successful restart. Assert only one inference task is active.

- [ ] **Step 2: Run worker tests to verify RED**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/OCRWorkerProtocolTests \
  -only-testing:ToolBoxTests/OCRWorkerClientTests CODE_SIGNING_ALLOWED=NO
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBoxOCRWorker -destination 'platform=macOS' \
  -only-testing:ToolBoxOCRWorkerTests/OCRWorkerServerTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure for missing worker targets and protocol types.

- [ ] **Step 3: Implement and package the worker**

Add a macOS command-line helper target copied to `ToolBox.app/Contents/Helpers/ToolBoxOCRWorker`. Copy its pinned runtime and dylibs into the application at build time, rewrite loader paths to bundle-relative locations and sign nested code before signing the app.

In `project.yml`, add `ToolBoxOCRWorker`, `ToolBoxOCRWorkerTests` and explicit shared schemes:
`ToolBox` tests `ToolBoxTests`, while `ToolBoxOCRWorker` tests `ToolBoxOCRWorkerTests`. Do not rely on
an implicit app scheme to discover the worker test bundle.

The client creates a `0700` session directory and `0600` PNG input, validates all response paths remain inside it, drains stdout/stderr concurrently and applies line/total-output limits. The worker permits one task, honors cancel, exits after five idle minutes and never reads arbitrary user paths. Cleanup is idempotent on success, failure, cancellation and app shutdown.

- [ ] **Step 4: Run tests, signing inspection and offline smoke test**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBoxOCRWorker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild archive -project ToolBox.xcodeproj -scheme ToolBox -configuration Release \
  -archivePath .build/ToolBox-OCR.xcarchive
codesign --verify --deep --strict .build/ToolBox-OCR.xcarchive/Products/Applications/ToolBox.app
scripts/ocr/run-architecture-gates.sh --configuration Release
```

Expected: tests, archive verification and offline worker gates pass. `notarytool` runs only in the configured release-signing environment and its result is attached to the gate report.

### Task 5: PP-StructureV3 structured layout pipeline

**Files:**
- Create: `Sources/ToolBox/OCR/PPStructureV3Service.swift`
- Create: `Sources/ToolBox/OCR/StructuredOCRDocument.swift`
- Create: `Sources/ToolBoxOCRWorker/PPStructureV3Adapter.swift`
- Create: `Tests/ToolBoxTests/PPStructureV3ServiceTests.swift`
- Add fixtures: `Tests/ToolBoxTests/Fixtures/OCR/structure-page.png`
- Add fixtures: `Tests/ToolBoxTests/Fixtures/OCR/structure-page-expected.json`
- Modify: `Sources/ToolBox/OCR/OCRResult.swift`

**Interfaces:**
- Produces: `OCRResult.structured(StructuredOCRDocument)` with typed title, paragraph, image, table and other layout blocks.

- [ ] **Step 1: Confirm the PP-StructureV3 gate**

Run Task 1's gate and require the report to identify a passing `ppStructureV3` worker. Stop this task on failure and keep PP-StructureV3 out of the shipped catalog/UI.

- [ ] **Step 2: Write failing schema and fixture tests**

Test layout type mapping, normalized polygons, block reading order, table cell spans, missing optional fields, unknown future block types, cancellation and malformed worker output.

- [ ] **Step 3: Implement the worker adapter and Swift projection**

Map upstream results once in the worker into the versioned ToolBox schema. Preserve unknown blocks as typed `other` values with geometry and safe metadata; do not coerce the result into text lines. Return structured errors for unsupported model/runtime combinations.

- [ ] **Step 4: Run focused tests and offline acceptance**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/PPStructureV3ServiceTests CODE_SIGNING_ALLOWED=NO
scripts/ocr/run-architecture-gates.sh --pipeline ppStructureV3 --configuration Release
```

Expected: fixtures pass within documented geometry/confidence tolerance and packet capture shows no network access during inference.

### Task 6: PaddleOCR-VL document pipeline

**Files:**
- Create: `Sources/ToolBox/OCR/PaddleOCRVLService.swift`
- Create: `Sources/ToolBox/OCR/DocumentParseResult.swift`
- Create: `Sources/ToolBoxOCRWorker/PaddleOCRVLAdapter.swift`
- Create: `Tests/ToolBoxTests/PaddleOCRVLServiceTests.swift`
- Add fixtures: `Tests/ToolBoxTests/Fixtures/OCR/vl-page.png`
- Add fixtures: `Tests/ToolBoxTests/Fixtures/OCR/vl-page-expected.json`
- Modify: `Sources/ToolBox/OCR/OCRResult.swift`

**Interfaces:**
- Produces: `OCRResult.document(DocumentParseResult)` with typed document blocks, Markdown and source-region associations.

- [ ] **Step 1: Confirm the PaddleOCR-VL gate**

Run Task 1's gate and require the report to identify a passing `paddleOCRVL` worker. Stop this task on failure and keep PaddleOCR-VL out of the shipped catalog/UI.

- [ ] **Step 2: Write failing document-result tests**

Cover block-to-Markdown association, normalized source polygons, reading order, unknown block types, Markdown size limit, cancellation, timeout, malformed UTF-8 and worker restart.

- [ ] **Step 3: Implement the worker adapter and Swift projection**

Keep document blocks and Markdown as one document result, enforce response size and nesting limits before decoding, and preserve block-to-source geometry. Never execute or render returned HTML/JavaScript; editor presentation treats Markdown as untrusted text.

- [ ] **Step 4: Run focused tests and offline acceptance**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/PaddleOCRVLServiceTests CODE_SIGNING_ALLOWED=NO
scripts/ocr/run-architecture-gates.sh --pipeline paddleOCRVL --configuration Release
```

Expected: fixtures pass within checked-in tolerance, memory stays below the gate threshold recorded for the pinned model, and no inference network traffic occurs.

### Task 7: Editor OCR layer, model manager and settings

**Files:**
- Create: `Sources/ToolBox/OCR/OCRCoordinator.swift`
- Create: `Sources/ToolBox/OCR/OCRResultLayer.swift`
- Create: `Sources/ToolBox/OCR/OCRModelManagerView.swift`
- Create: `Sources/ToolBox/OCR/OCRSettingsStore.swift`
- Create: `Tests/ToolBoxTests/OCRCoordinatorTests.swift`
- Create: `Tests/ToolBoxTests/OCRSettingsStoreTests.swift`
- Modify: `Sources/ToolBox/Screenshot/Editor/ScreenshotDocument.swift`
- Modify: `Sources/ToolBox/Screenshot/Editor/ScreenshotEditorView.swift`
- Modify: `Sources/ToolBox/Screenshot/ScreenshotSettingsView.swift`
- Modify: `Sources/ToolBox/AppDelegate.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: current immutable base image, selected pipeline, verified model leases and local services.
- Produces: cancellable OCR jobs, separate result layers, copy-text/Markdown actions and model lifecycle UI.

- [ ] **Step 1: Write failing coordinator and settings tests**

Test default tiny selection, explicit download confirmation, offline installed use, unavailable advanced-pipeline filtering, run/cancel/retry, stale result suppression after document close, model lease lifetime, delete protection, app-stop cleanup, corrupt settings fallback and no-cloud invariant.

- [ ] **Step 2: Run focused tests to verify RED**

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/OCRCoordinatorTests \
  -only-testing:ToolBoxTests/OCRSettingsStoreTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure for missing coordinator and settings store.

- [ ] **Step 3: Add the editor result experience**

Add one OCR command that uses the selected installed pipeline. Text results show selectable lines and synchronized polygon highlights. Structured results show layout blocks and table previews. VL results show document blocks plus copyable Markdown. OCR overlays are toggleable and never flatten into PNG unless the user converts selected OCR text into an explicit text annotation.

Expose progress, cancel, retry and typed failure states without blocking annotation editing.

- [ ] **Step 4: Add functional model and pipeline settings**

The Screenshot settings page shows only pipelines whose Task 1 gate artifacts support the current
CPU architecture and device class. Provide PP-OCRv6 tiny/small/medium selection, default tiny, model
version/size/license, download progress, validation, update and delete. Mark tiny as not supporting
Japanese and require small or medium when Japanese is selected. Show PP-StructureV3 and PaddleOCR-VL
separately when their worker gates passed. Make “local only, no cloud fallback” explicit beside model
controls.

- [ ] **Step 5: Run complete verification**

```bash
scripts/ocr/fetch-runtime-dependencies.sh --verify-only
scripts/ocr/run-architecture-gates.sh --configuration Release
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBoxOCRWorker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project ToolBox.xcodeproj -scheme ToolBox -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project ToolBox.xcodeproj -scheme ToolBox -configuration Release \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
git diff --check
```

Expected: integrity/gate scripts, all tests and both builds pass.

- [ ] **Step 6: Complete manual and release acceptance**

Test all three PP-OCRv6 profiles with simplified/traditional Chinese and English; test Japanese with small/medium and verify tiny produces the explicit unsupported-language state. Test every gated advanced pipeline with Chinese, English, Japanese and mixed text; first download, cancel, resume/retry, corruption, update, delete, disk-full and offline operation; editor layer alignment at multiple zooms; helper crash recovery; app quit during inference; signed archive, notarization and packet-captured proof of no inference network traffic.
