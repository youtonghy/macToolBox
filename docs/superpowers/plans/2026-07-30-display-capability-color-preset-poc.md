# Display Capability and Controlled Color Preset POC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add safe Capability String discovery and an experimental, fail-closed VCP `0x14` color preset workflow for verified displays while preserving all existing DDC controls.

**Architecture:** Keep `DarwinDisplayControlProvider` as the single serialized hardware boundary and extend `DDCTransport` with typed feature-read and Capability String operations. Store the raw per-display capability report separately from one-shot DDC read outcomes, project only advertised preset values into the public display snapshot, and route preset writes through a dedicated verified-write API. `DisplayControlService` owns latest-wins preset scheduling; the menu model/view only renders the experimental control when the provider reports a writable preset list.

**Tech Stack:** Swift 5, Swift Concurrency, Combine, SwiftUI, XCTest, CoreGraphics, IOKit I2C, IOAVService, XcodeGen, macOS 14.0.

## Global Constraints

- Treat `/Users/youtonghy/Downloads/break/DDPM/11-authoritative-spec.md` as the single protocol/design source for this POC.
- Preserve the current provider → service → menu model → SwiftUI view ownership split.
- Preserve existing brightness, contrast, volume, mute, media-key, scheduling, write-only, and display lifecycle behavior.
- Keep deployment target at macOS 14.0 and add no third-party dependency.
- Use only Apple Silicon IOAVService and Intel IOKit I2C; do not integrate Dell USB SDK or USB fallback.
- Capability parsing is all-or-nothing for `vcp(...)`; malformed or incomplete data must fail closed.
- Preserve every raw advertised enum value. Do not intersect it with a global MCCS table.
- Unknown display identities and unknown preset values must not receive guessed gamut names.
- The production UI remains hidden unless the experimental feature flag is enabled and the display has an allowlisted preset mapping.
- A VCP `0x14` transport write is not success until Get VCP reads back the requested raw value.
- After a verified preset write, invalidate and refresh brightness and contrast.
- Do not implement RGB Gain, MinLu exceptions, HDR detection/switching, ICC, reverse synchronization, scheduling, per-app switching, or remote assets.
- Do not commit, revert, overwrite, or reformat unrelated worktree changes.
- Existing uncommitted changes in `DDCTransport.swift`, `Arm64DDCBackend.swift`, `IntelDDCBackend.swift`, and `DisplayControlCapabilityTests.swift` are the implementation baseline; normalize and extend them instead of discarding them.
- Use TDD for every production behavior: run the focused test and observe RED, implement the smallest coherent change, then observe GREEN.
- Hardware observations are evidence, not silent constants: record them in the acceptance log and update the authoritative spec before promoting behavior beyond POC.

## Current Baseline

- Focused DisplayControl tests pass: 34 tests, 0 failures.
- Baseline verification command:

```bash
xcodebuild test \
  -project ToolBox.xcodeproj \
  -scheme ToolBox \
  -configuration Debug \
  -derivedDataPath /tmp/macToolBox-display-poc-plan \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ToolBoxTests/DisplayControlCapabilityTests \
  -only-testing:ToolBoxTests/DisplayControlValueStoreTests \
  -only-testing:ToolBoxTests/DisplayControlServiceTests \
  -only-testing:ToolBoxTests/DisplayControlMenuModelTests
```

- If XCTest reports `com.apple.testmanagerd.control` sandbox errors, rerun the exact command outside the command sandbox; do not treat that infrastructure failure as a product test failure.

## File Map

- Modify `Sources/ToolBox/DisplayControl/Darwin/DDCTransport.swift`: typed read outcomes, raw Capability String block parser, transport contract, VCP codes.
- Modify `Sources/ToolBox/DisplayControl/Darwin/Arm64DDCBackend.swift`: 11-byte Get VCP reads and 50-byte `0xF3` Capability String block reads over IOAVService.
- Modify `Sources/ToolBox/DisplayControl/Darwin/IntelDDCBackend.swift`: 11-byte Get VCP reads and 50-byte `0xF3` Capability String block reads over IOKit I2C.
- Create `Sources/ToolBox/DisplayControl/Darwin/DisplayCapabilityStore.swift`: per-display capability cache and registry-backed connection-token invalidation.
- Create `Sources/ToolBox/DisplayControl/DisplayColorPresetModels.swift`: public preset option/state/result models and verified identity mappings.
- Modify `Sources/ToolBox/DisplayControl/DisplayControlModels.swift`: provider protocol additions and per-display color preset projection.
- Modify `Sources/ToolBox/DisplayControl/Darwin/DarwinDisplayControlProvider.swift`: capability discovery, fail-closed projection, verified preset write/readback, brightness/contrast invalidation.
- Modify `Sources/ToolBox/DisplayControl/DisplayControlService.swift`: latest-wins preset worker and cancellation during stop/sleep/reconfiguration.
- Modify `Sources/ToolBox/DisplayControl/DisplayControlMenuModel.swift`: selected-display preset items, pending selection, errors, experimental flag.
- Modify `Sources/ToolBox/DisplayControl/DisplayControlPanel.swift`: compact preset Picker and failure presentation.
- Create `Sources/ToolBox/DisplayControl/DisplayControlExperimentalFeatures.swift`: injectable UserDefaults-backed POC flag.
- Expand `Tests/ToolBoxTests/DisplayControlCapabilityTests.swift`: reply and capability parser tests.
- Create `Tests/ToolBoxTests/DisplayCapabilityStoreTests.swift`: cache and invalidation tests.
- Create `Tests/ToolBoxTests/DarwinDisplayColorPresetProviderTests.swift`: provider fail-closed and readback tests using fake transports.
- Expand `Tests/ToolBoxTests/DisplayControlServiceTests.swift`: preset latest-wins/cancellation tests.
- Expand `Tests/ToolBoxTests/DisplayControlMenuModelTests.swift`: UI projection and flag tests.
- Create `docs/testing/display-color-preset-poc-acceptance.md`: §12.2 evidence capture template and promotion gates.
- Modify `/Users/youtonghy/Downloads/break/DDPM/11-authoritative-spec.md` only after real hardware results exist and only with explicit permission, because it is outside the repository writable root.

---

### Task 1: Normalize Typed DDC Read Outcomes

**Files:**
- Modify: `Sources/ToolBox/DisplayControl/Darwin/DDCTransport.swift`
- Modify: `Sources/ToolBox/DisplayControl/Darwin/Arm64DDCBackend.swift`
- Modify: `Sources/ToolBox/DisplayControl/Darwin/IntelDDCBackend.swift`
- Modify: `Tests/ToolBoxTests/DisplayControlCapabilityTests.swift`

**Interfaces:**
- Produces: `DDCReadOutcome`
- Produces: `DDCReadFailure`
- Produces: `DDCFeatureReplyParser.parse(_:expectedCommand:)`
- Preserves: `DDCTransport.read(command:options:)` as a compatibility wrapper during this task

- [ ] **Step 1: Replace the coarse parser assertions with failing typed-outcome tests**

Add tests that assert the exact failure cause:

```swift
func testFeatureReplyParserPreservesUnsupportedResultCode() {
    let reply = featureReply(command: 0x14, resultCode: 0x01, maximum: 0, current: 0)
    XCTAssertEqual(
        DDCFeatureReplyParser.parse(reply, expectedCommand: 0x14),
        .failure(.unsupportedReply(resultCode: 0x01))
    )
}

func testFeatureReplyParserSeparatesMalformedChecksumAndEcho() {
    var checksumFailure = featureReply(command: 0x10, maximum: 100, current: 75)
    checksumFailure[10] ^= 0xFF
    XCTAssertEqual(
        DDCFeatureReplyParser.parse(checksumFailure, expectedCommand: 0x10),
        .failure(.checksumMismatch)
    )

    let echoFailure = featureReply(command: 0x12, maximum: 100, current: 75)
    XCTAssertEqual(
        DDCFeatureReplyParser.parse(echoFailure, expectedCommand: 0x10),
        .failure(.unexpectedCommand(expected: 0x10, actual: 0x12))
    )
}

func testFeatureReplyParserPreservesInvalidSentinel() {
    let reply = featureReply(command: 0x10, maximum: 0xFFFF, current: 0xFFFF)
    XCTAssertEqual(
        DDCFeatureReplyParser.parse(reply, expectedCommand: 0x10),
        .failure(.invalidSentinel)
    )
}
```

Add one private test helper that creates the 11-byte reply and computes checksum from seed `0x50` over bytes `[0...9]`.

- [ ] **Step 2: Run the focused test and observe RED**

```bash
xcodebuild test \
  -project ToolBox.xcodeproj \
  -scheme ToolBox \
  -configuration Debug \
  -derivedDataPath /tmp/macToolBox-display-poc-task1 \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ToolBoxTests/DisplayControlCapabilityTests
```

Expected: compile failures because the typed failure cases do not exist.

- [ ] **Step 3: Implement the typed internal model**

Use:

```swift
enum DDCReadOutcome: Equatable {
    case success(DDCReadResult)
    case failure(DDCReadFailure)
}

enum DDCReadFailure: Error, Equatable {
    case unsupportedReply(resultCode: UInt8)
    case invalidSentinel
    case checksumMismatch
    case malformedReply
    case unexpectedCommand(expected: UInt8, actual: UInt8)
    case transportFailure
}
```

Parser order must be:

1. exactly 11 valid bytes;
2. source byte `0x6E`;
3. length/subtype;
4. checksum;
5. VCP echo;
6. nonzero result code;
7. `0xFFFF` sentinel;
8. success with value type/max/current.

Keep `read(command:options:)` as:

```swift
func read(command: UInt8, options: DDCRequestOptions) -> DDCReadResult? {
    guard case let .success(result) = readOutcome(command: command, options: options) else {
        return nil
    }
    return result
}
```

The concrete backends return `.failure(.transportFailure)` only when no validated reply was produced after configured attempts.

- [ ] **Step 4: Run focused and current DisplayControl tests**

Run the Task 1 command, followed by the 34-test baseline command from “Current Baseline”.

Expected: all selected tests pass.

- [ ] **Step 5: Review the existing dirty diff rather than committing blindly**

```bash
git diff --check
git diff -- \
  Sources/ToolBox/DisplayControl/Darwin/DDCTransport.swift \
  Sources/ToolBox/DisplayControl/Darwin/Arm64DDCBackend.swift \
  Sources/ToolBox/DisplayControl/Darwin/IntelDDCBackend.swift \
  Tests/ToolBoxTests/DisplayControlCapabilityTests.swift
```

Expected: no whitespace errors; existing user changes are preserved and now conform to the authoritative outcome model.

---

### Task 2: Make Capability Parsing Strict and Lossless

**Files:**
- Modify: `Sources/ToolBox/DisplayControl/Darwin/DDCTransport.swift`
- Modify: `Tests/ToolBoxTests/DisplayControlCapabilityTests.swift`

**Interfaces:**
- Produces: `DDCAdvertisedSupport`
- Produces: `DDCCapabilityReport.enumValues: [UInt8: Set<UInt8>]`
- Produces: `DDCCapabilityParser.parse(_:) -> Result<DDCCapabilityReport, DDCCapabilityParseFailure>`

- [ ] **Step 1: Add failing parser tests for the authoritative edge cases**

Add:

```swift
func testCapabilityParserPreservesUnknownPresetValues() throws {
    let report = try DDCCapabilityParser.parse(
        "prot(monitor)vcp(10 14(0B 41 A7) 60(01 0F))"
    ).get()
    XCTAssertEqual(report.enumValues[0x14], [0x0B, 0x41, 0xA7])
}

func testCapabilityParserDistinguishesMissingAndEmptyPresetSubset() throws {
    let noPreset = try DDCCapabilityParser.parse("vcp(10 12 60(01))").get()
    XCTAssertEqual(noPreset.support(for: 0x14), .notAdvertised)

    let emptyPreset = try DDCCapabilityParser.parse("vcp(10 12 14 60(01))").get()
    XCTAssertEqual(emptyPreset.support(for: 0x14), .advertisedNoEnumSubset)
}

func testCapabilityParserRejectsTruncatedOrInvalidVCPBlocks() {
    XCTAssertEqual(
        DDCCapabilityParser.parse("prot(monitor)vcp(10 14(0B 41)"),
        .failure(.unterminatedVCPBlock)
    )
    XCTAssertEqual(
        DDCCapabilityParser.parse("vcp(10 14(0B ZZ))"),
        .failure(.invalidHexToken("ZZ"))
    )
}
```

- [ ] **Step 2: Run `DisplayControlCapabilityTests` and observe RED**

Use the Task 1 focused command with derived data path `/tmp/macToolBox-display-poc-task2`.

Expected: compile failures for `enumValues`, `support(for:)`, and typed parse failures.

- [ ] **Step 3: Implement strict all-or-nothing parsing**

Use:

```swift
enum DDCAdvertisedSupport: Equatable, Sendable {
    case advertisedWithSubset(Set<UInt8>)
    case advertisedNoEnumSubset
    case notAdvertised
    case capabilityStringUnavailable
}

struct DDCCapabilityReport: Equatable, Sendable {
    let supportedVCPs: Set<UInt8>
    let enumValues: [UInt8: Set<UInt8>]
    let rawString: String

    func support(for code: UInt8) -> DDCAdvertisedSupport
}
```

Parsing rules:

- Find one complete `vcp(...)` section with balanced parentheses.
- Accept ASCII whitespace and case-insensitive two-digit hex tokens.
- Reject invalid tokens, nested depth beyond enum-value depth, and trailing truncation.
- Preserve all advertised values including unknown vendor values.
- Never return a partial capability report after malformed input.

- [ ] **Step 4: Run parser tests and `git diff --check`**

Expected: parser tests pass; no malformed input produces a writable subset.

- [ ] **Step 5: Record the checkpoint**

Do not commit unless the user asks. Inspect the exact dirty files with `git status --short`.

---

### Task 3: Add Capability Block Decoding and Transport Contract

**Files:**
- Modify: `Sources/ToolBox/DisplayControl/Darwin/DDCTransport.swift`
- Modify: `Tests/ToolBoxTests/DisplayControlCapabilityTests.swift`

**Interfaces:**
- Produces: `DDCCapabilityBlock`
- Produces: `DDCCapabilityBlockParser.parse(_:expectedOffset:)`
- Produces: `DDCTransport.readCapabilityString(options:) -> Result<String, DDCCapabilityReadFailure>`
- Produces: `DDCTransport.connectionToken: UInt64?`

- [ ] **Step 1: Add failing capability-block tests**

Cover:

```swift
func testCapabilityBlockParsesPayloadAndOffset() throws
func testCapabilityBlockAcceptsZeroLengthTerminator() throws
func testCapabilityBlockRejectsLengthPastBuffer() 
func testCapabilityBlockRejectsChecksumMismatch()
func testCapabilityBlockRejectsUnexpectedOffset()
func testCapabilityStringAssemblerRejectsNonASCIIAndOversizedOutput()
```

Use actual block shape:

```text
[0] source
[1] 0x83 + payloadLength
[2] 0xE3
[3] offsetHigh
[4] offsetLow
[5 ..< 5 + payloadLength] payload
[5 + payloadLength] checksum
```

The test helper must compute response checksum with seed `0x50` across every byte before the checksum. Include a 50-byte buffer with a short payload to prove unused tail bytes are ignored.

- [ ] **Step 2: Run focused tests and observe RED**

Expected: missing block parser and transport capability API.

- [ ] **Step 3: Implement defensive block parsing and assembly**

Use:

```swift
struct DDCCapabilityBlock: Equatable {
    var offset: UInt16
    var payload: [UInt8]
    var isTerminator: Bool { payload.isEmpty }
}

enum DDCCapabilityReadFailure: Error, Equatable {
    case transportFailure
    case invalidBlock
    case unexpectedOffset(expected: UInt16, actual: UInt16)
    case invalidASCII
    case exceededMaximumLength
    case tooManyConsecutiveFailures
}
```

Hard limits for the POC:

- read buffer: 50 bytes;
- maximum accumulated capability string: 16 KiB;
- maximum consecutive failed blocks: 10;
- terminate only on a valid zero-length block at the expected offset.

Add `readCapabilityString(options:)` to `DDCTransport`; its default implementation returns `.failure(.transportFailure)` so test fakes and unrelated conformers remain source-compatible until Tasks 4–5.

Add optional `connectionToken` to the transport contract. It identifies one concrete IOKit connection lifetime, not the display model. Test fakes receive an explicit token. Live backends override it in Tasks 4–5 using `IORegistryEntryGetRegistryEntryID`; do not derive it from `displayID`, display name, or `ObjectIdentifier`. A missing token disables Capability/preset discovery but must not disable existing brightness/contrast/audio DDC operations.

- [ ] **Step 4: Run capability parser/block tests**

Expected: all block boundary, checksum, offset, ASCII, and termination tests pass.

- [ ] **Step 5: Review for memory safety**

Confirm every array access is preceded by a checked minimum/derived length. Run:

```bash
git diff --check
rg -n "payloadLength|expectedOffset|16_384" Sources/ToolBox/DisplayControl/Darwin/DDCTransport.swift
```

---

### Task 4: Implement Apple Silicon Capability String Reads

**Files:**
- Modify: `Sources/ToolBox/DisplayControl/Darwin/Arm64DDCBackend.swift`
- Modify: `Tests/ToolBoxTests/DisplayControlCapabilityTests.swift`

**Interfaces:**
- Consumes: `DDCCapabilityBlockParser`
- Produces: `Arm64DDCBackend.readCapabilityString(options:)`
- Produces internal injectable raw I2C closures for deterministic unit tests

- [ ] **Step 1: Extract an injectable raw-I2C seam and write failing sequence tests**

Add a package-internal initializer used only by tests:

```swift
init(
    backendName: String,
    connectionToken: UInt64?,
    writeI2C: @escaping ([UInt8]) -> Bool,
    readI2C: @escaping (Int) -> [UInt8]?,
    sleepMicros: @escaping (UInt32) -> Void
)
```

Tests must assert:

- request bytes for offset zero are `[0x83, 0xF3, 0x00, 0x00, 0x4F]`;
- second request advances by the previous payload length;
- two nonempty blocks plus a zero-length terminator produce one ASCII string;
- a failed block is retried at the same offset;
- eleven consecutive failed blocks return `.tooManyConsecutiveFailures`;
- no Dell USB fallback is invoked.

- [ ] **Step 2: Run the new Apple Silicon transport tests and observe RED**

Expected: initializer/read method do not exist.

- [ ] **Step 3: Implement the IOAVService sequence**

The live closures call:

```swift
IOAVServiceWriteI2C(service, 0x37, 0x51, request, 5)
IOAVServiceReadI2C(service, 0x37, 0x51, &reply, 50)
```

Construct checksum:

```swift
let checksum = offsetHigh ^ offsetLow ^ 0x4F
```

Use the existing serialized provider queue; do not create another hardware queue. Sleep 60 ms between request and read, but inject the sleeper so tests use zero delay.

Populate `connectionToken` from the registry entry ID captured before converting the matched IOKit service to `IOAVService`. Preserve the optional token in `Arm64DDCServiceMatch` and pass it to the backend initializer. If it is unavailable, retain the backend for existing controls but return capability-unavailable without performing uncached discovery.

- [ ] **Step 4: Run focused transport and existing Arm64 communication tests**

Expected: all pass, including the prior “read failure does not reuse successful write result” test.

- [ ] **Step 5: Build without launching**

```bash
CONFIG=Debug OPEN=0 ./build.sh
```

Expected: `** BUILD SUCCEEDED **`.

---

### Task 5: Implement Intel Capability String Reads

**Files:**
- Modify: `Sources/ToolBox/DisplayControl/Darwin/IntelDDCBackend.swift`
- Modify: `Tests/ToolBoxTests/DisplayControlCapabilityTests.swift`

**Interfaces:**
- Consumes: `DDCCapabilityBlockParser`
- Produces: `IntelDDCBackend.readCapabilityString(options:)`
- Preserves existing framebuffer/bus discovery and reply transaction selection

- [ ] **Step 1: Add failing Intel request/sequence tests through an injected send seam**

Add a package-internal initializer:

```swift
init(
    backendName: String,
    connectionToken: UInt64?,
    performTransaction: @escaping (_ request: [UInt8], _ replyLength: Int) -> [UInt8]?,
    sleepMicros: @escaping (UInt32) -> Void
)
```

Assert:

- request is `[0x51, 0x83, 0xF3, offHi, offLo, offHi ^ offLo ^ 0x4F]`;
- `sendAddress = 0x6E`;
- reply address/subaddress remain `0x6F`/`0x51`;
- reply buffer is 50 bytes;
- offset advances only after a valid block;
- the same strict terminator and failure limit from Task 3 apply.

- [ ] **Step 2: Run focused tests and observe RED**

Expected: Intel capability operation is missing.

- [ ] **Step 3: Implement the Intel IOI2C request**

Reuse the existing `send(request:to:errorRecoveryWaitMicros:)` bus traversal. Do not duplicate framebuffer discovery. Use the transport-level capability assembler so Intel and Apple Silicon share all block validation.

Populate `connectionToken` from `IORegistryEntryGetRegistryEntryID(framebuffer, &token)`. If the registry call fails, retain the backend for existing controls but return capability-unavailable without caching or attempting preset writes.

- [ ] **Step 4: Run all `DisplayControlCapabilityTests`**

Expected: typed Get VCP, parser, Arm64 and Intel capability tests pass.

- [ ] **Step 5: Run Debug build and inspect backend diffs**

```bash
CONFIG=Debug OPEN=0 ./build.sh
git diff --check
```

---

### Task 6: Add Per-Display Capability Cache and Invalidation

**Files:**
- Create: `Sources/ToolBox/DisplayControl/Darwin/DisplayCapabilityStore.swift`
- Create: `Tests/ToolBoxTests/DisplayCapabilityStoreTests.swift`

**Interfaces:**
- Produces: `DisplayHardwareIdentity`
- Produces: `DisplayCapabilityCacheKey`
- Produces: `DisplayCapabilityStore.report(for:)`
- Produces: `record(_:for:)`
- Produces: `retainConnections(_:)`
- Produces: `invalidate(displayID:)`

- [ ] **Step 1: Write failing cache tests**

Cover:

```swift
func testReportIsReusedForSameConnectionToken()
func testConnectionTokenChangeInvalidatesCachedCapability()
func testDisconnectRemovesCachedCapability()
func testFailedCapabilityReadIsNotPermanentlyCached()
```

Use separate hardware and connection identities:

```swift
struct DisplayHardwareIdentity: Hashable, Sendable {
    var vendorNumber: UInt32?
    var modelNumber: UInt32?
    var serialNumber: UInt32?
}

struct DisplayCapabilityCacheKey: Hashable, Sendable {
    var displayID: CGDirectDisplayID
    var hardwareIdentity: DisplayHardwareIdentity
    var backendName: String
    var connectionToken: UInt64
}
```

- [ ] **Step 2: Run focused tests and observe RED**

Expected: cache types are missing.

- [ ] **Step 3: Implement an in-memory cache**

The cache stores successful complete reports only. It never persists capability strings to UserDefaults in this POC. A stable registry-entry `connectionToken` plus exact hardware identity reuses the report across ordinary snapshots; reconnecting through a new IOKit registry entry creates a new key. Changed token/identity/backend or display removal invalidates the old entry. A nil token is never converted into a cache key.

- [ ] **Step 4: Run cache tests**

Expected: all pass.

- [ ] **Step 5: Review retention behavior**

Verify cache size is bounded by current transports and raw strings by the 16 KiB parser cap.

---

### Task 7: Add Public Color Preset Models and Verified Allowlist

**Files:**
- Create: `Sources/ToolBox/DisplayControl/DisplayColorPresetModels.swift`
- Create: `Sources/ToolBox/DisplayControl/DisplayControlExperimentalFeatures.swift`
- Modify: `Sources/ToolBox/DisplayControl/DisplayControlModels.swift`
- Create: `Tests/ToolBoxTests/DisplayColorPresetModelsTests.swift`
- Create: `Tests/ToolBoxTests/DisplayControlExperimentalFeaturesTests.swift`

**Interfaces:**
- Produces: `DisplayColorPresetOption`
- Produces: `DisplayColorPresetCapability`
- Produces: `DisplayColorPresetWriteResult`
- Produces: `DisplayColorPresetError`
- Produces: `DisplayControlExperimentalFeatures.colorPresetPOCEnabled`
- Produces: `DisplayColorPresetCatalog.options(identity:advertisedValues:)`
- Extends: `DisplayControlDisplay.colorPreset`
- Extends: `DisplayControlProviding.writeColorPreset(displayID:rawValue:)`

- [ ] **Step 1: Write failing model/catalog tests**

Tests:

```swift
func testUnknownIdentityReturnsNoWritableFriendlyOptions()
func testAllowlistedIdentityOnlyReturnsAdvertisedValues()
func testUnknownAdvertisedValueIsPreservedForDiagnosticsButNotWritable()
func testDuplicateDisplayNamesDoNotAffectIdentityMatching()
func testCodableSnapshotRoundTripsColorPresetCapability()
func testExperimentalColorPresetFlagDefaultsOff()
```

Use:

```swift
struct DisplayColorPresetOption: Codable, Equatable, Identifiable, Sendable {
    var id: UInt8 { rawValue }
    var rawValue: UInt8
    var name: String
}

enum DisplayColorPresetStatus: String, Codable, Sendable {
    case available
    case unavailable
    case unsupported
}

struct DisplayColorPresetCapability: Codable, Equatable, Sendable {
    var status: DisplayColorPresetStatus
    var currentRawValue: UInt8?
    var options: [DisplayColorPresetOption]
    var advertisedRawValues: [UInt8]
    var unavailableReason: String?
}

struct DisplayColorPresetWriteResult: Equatable, Sendable {
    var displayID: CGDirectDisplayID
    var requestedRawValue: UInt8
    var verifiedRawValue: UInt8
    var verifiedAt: Date
}

enum DisplayColorPresetError: Error, Equatable, LocalizedError {
    case providerUnsupported
    case capabilityUnavailable
    case presetNotAdvertised
    case unverifiedDisplayIdentity
    case valueNotAdvertised(UInt8)
    case transportWriteFailed
    case readbackFailed
    case verificationMismatch(requested: UInt8, lastObserved: UInt8?)

    var errorDescription: String? {
        switch self {
        case .providerUnsupported:
            return "Color preset control is unavailable from this display provider."
        case .capabilityUnavailable:
            return "The display capability report is unavailable."
        case .presetNotAdvertised:
            return "The display did not advertise color preset control."
        case .unverifiedDisplayIdentity:
            return "This display identity has no verified color preset mapping."
        case let .valueNotAdvertised(value):
            return String(format: "Preset 0x%02X was not advertised by this display.", value)
        case .transportWriteFailed:
            return "The display rejected the color preset write."
        case .readbackFailed:
            return "The color preset could not be read back."
        case let .verificationMismatch(requested, lastObserved):
            let actual = lastObserved.map { String(format: "0x%02X", $0) } ?? "unknown"
            return String(
                format: "Preset 0x%02X was requested, but the display reported %@.",
                requested,
                actual
            )
        }
    }
}
```

Extend the snapshot model with an optional property that preserves source compatibility:

```swift
struct DisplayControlDisplay: Codable, Equatable, Identifiable, Sendable {
    // Existing fields remain unchanged.
    var colorPreset: DisplayColorPresetCapability? = nil
}
```

- [ ] **Step 2: Run focused tests and observe RED**

Expected: color preset public types do not exist.

- [ ] **Step 3: Implement the catalog with an empty production allowlist**

Set the production catalog to `DisplayColorPresetCatalog(entries: [])`. Do not seed guessed Dell mappings from DDPM. Tasks 8–12 use explicitly constructed test catalogs such as vendor `0x10AC`, model `0x0001`, serial `0x0000002A`, values `0x0B = "Verified sRGB"` and `0x41 = "Verified HDR Preview"`; these are fixture identities/names only and never ship in the production catalog.

Implement the UserDefaults-backed feature store with:

```swift
static let colorPresetPOCKey = "displayControl.experimental.colorPresetPOC"
```

The default is false. The provider, service, and menu model receive an injectable `() -> Bool`; Task 8 uses this closure to skip both Capability String reads and preset writes while disabled.

Protocol addition:

```swift
func writeColorPreset(
    displayID: CGDirectDisplayID,
    rawValue: UInt8
) async throws -> DisplayColorPresetWriteResult
```

Provide a default protocol-extension implementation that throws `DisplayColorPresetError.providerUnsupported`, so existing provider fakes remain source-compatible. Do not add `.colorPreset` to `DisplayControlKind`, because slider semantics and normalized values do not apply.

- [ ] **Step 4: Run model tests and compile all existing provider fakes**

Expected: existing tests compile without adding stub methods to every fake provider.

- [ ] **Step 5: Review API boundary**

Confirm preset values remain `UInt8` raw enums throughout and are never converted to `Double`.

---

### Task 8: Integrate Capability Discovery into Darwin Provider

**Files:**
- Modify: `Sources/ToolBox/DisplayControl/Darwin/DarwinDisplayControlProvider.swift`
- Modify: `Sources/ToolBox/DisplayControl/Darwin/DisplayCapabilityStore.swift`
- Create: `Tests/ToolBoxTests/DarwinDisplayColorPresetProviderTests.swift`

**Interfaces:**
- Consumes: `DDCTransport.readCapabilityString(options:)`
- Consumes: `DisplayCapabilityStore`
- Consumes: `DisplayColorPresetCatalog`
- Consumes: experimental feature-enabled closure
- Produces: `DisplayControlDisplay.colorPreset`

- [ ] **Step 1: Add a transport factory seam and failing provider tests**

Construct the provider with injected:

```swift
init(
    onlineDisplayIDs: @escaping () -> [CGDirectDisplayID],
    identity: @escaping (CGDirectDisplayID) -> DisplayHardwareIdentity,
    transportFactory: @escaping (CGDirectDisplayID) -> DDCTransport?,
    presetCatalog: DisplayColorPresetCatalog,
    colorPresetPOCEnabled: @escaping () -> Bool
)
```

Tests:

- complete cap string with `14(0B 41)` + allowlisted identity → exactly mapped options;
- complete cap string + unknown identity → advertised values retained, preset unavailable;
- `14` without subset → unavailable;
- malformed/failed cap string → unavailable and no write method exposure;
- disabled experimental flag → no Capability String read and all preset writes rejected;
- two snapshots with the same connection token read cap string once;
- reconnect with a new connection token reads it again;
- existing brightness/contrast controls remain present.

- [ ] **Step 2: Run provider tests and observe RED**

Expected: injection points and color preset projection do not exist.

- [ ] **Step 3: Implement serialized discovery**

During `snapshot()`:

1. refresh transports and their registry-backed connection tokens;
2. if the experimental flag is disabled, project no preset capability and skip capability I/O;
3. get a cached complete report or read/parse one;
4. query current `0x14` only when support is `advertisedWithSubset`;
5. resolve allowlisted names;
6. project `DisplayColorPresetCapability`;
7. never change existing slider capability behavior because cap discovery failed.

Capability failure disables only enum features; it must not remove the transport or disable brightness/contrast.

- [ ] **Step 4: Run provider and 34-test baseline**

Expected: provider tests and all existing DisplayControl tests pass.

- [ ] **Step 5: Inspect DDC operation count**

Assert each snapshot performs at most one Capability String read per connection token and one `0x14` Get VCP when preset support is usable.

---

### Task 9: Implement Verified Preset Write and Readback

**Files:**
- Modify: `Sources/ToolBox/DisplayControl/Darwin/DarwinDisplayControlProvider.swift`
- Modify: `Sources/ToolBox/DisplayControl/Darwin/DisplayControlValueStore.swift`
- Modify: `Tests/ToolBoxTests/DarwinDisplayColorPresetProviderTests.swift`

**Interfaces:**
- Produces: `DarwinDisplayControlProvider.writeColorPreset(displayID:rawValue:)`
- Produces: `DisplayColorPresetWriteResult`
- Consumes: per-display advertised subset and allowlist

- [ ] **Step 1: Write failing state-machine tests**

Cover:

```swift
func testPresetWriteRejectsValueOutsideAdvertisedSubset()
func testPresetWriteRejectsUnknownIdentityEvenWhenValueIsAdvertised()
func testPresetWriteDoesNotReportSuccessWhenTransportWriteFails()
func testPresetWriteRetriesReadbackUntilRequestedValueAppears()
func testPresetWriteFailsWhenReadbackNeverMatches()
func testVerifiedPresetWriteInvalidatesBrightnessAndContrastValues()
func testUnsupportedReplyDoesNotRetryForever()
```

Inject a sleeper and verification policy:

```swift
struct DisplayColorPresetVerificationPolicy: Sendable {
    var initialDelayNanos: UInt64
    var retryDelayNanos: UInt64
    var maximumReadAttempts: Int

    static let poc = Self(
        initialDelayNanos: 200_000_000,
        retryDelayNanos: 200_000_000,
        maximumReadAttempts: 3
    )
}
```

- [ ] **Step 2: Run provider tests and observe RED**

Expected: write API/state machine missing.

- [ ] **Step 3: Implement the verified transaction**

Inside the provider’s existing serial queue:

1. require the experimental flag to remain enabled;
2. ensure display online and transport present;
3. require complete cached capability report for the current connection token;
4. require `rawValue` in advertised subset;
5. require catalog authorization for exact hardware identity/value;
6. write VCP `0x14`;
7. sleep according to injected policy;
8. read VCP `0x14` up to the configured limit;
9. return success only when `current == rawValue`;
10. call `valueStore.invalidate(displayID:kinds:)` for `.brightness` and `.contrast`;
11. return a typed error with transport/readback cause otherwise.

Add this focused value-store API:

```swift
mutating func invalidate(
    displayID: CGDirectDisplayID,
    kinds: Set<DisplayControlKind>
)
```

It removes observed values and last-successful raw values for those keys, but does not erase the persisted brightness-memory fallback.

Do not roll hardware back after ICC or readback failure; ICC is not part of this POC.

- [ ] **Step 4: Run provider tests and all DisplayControl tests**

Expected: all pass.

- [ ] **Step 5: Verify logs contain safe diagnostics**

Logs may contain display ID, vendor/model/serial numeric identity, backend, VCP, raw request value, attempt count, and failure class. They must not contain user paths, ICC data, or unrelated system information.

---

### Task 10: Add Latest-Wins Preset Scheduling to the Service

**Files:**
- Modify: `Sources/ToolBox/DisplayControl/DisplayControlService.swift`
- Modify: `Tests/ToolBoxTests/DisplayControlServiceTests.swift`

**Interfaces:**
- Produces: `DisplayControlService.setColorPreset(displayID:rawValue:)`
- Produces: `DisplayControlService.presentedColorPreset(displayID:)`
- Consumes: provider `writeColorPreset`

- [ ] **Step 1: Extend the recording provider and write failing concurrency tests**

Add raw preset write recording separate from normalized slider writes. Tests:

```swift
func testPresetBurstKeepsOnlyInFlightAndLatestValue()
func testPresetFailureRestoresLastVerifiedSelection()
func testSleepCancelsPendingPresetWork()
func testDisplayReconfigurationDropsPresetWorkForRemovedDisplay()
func testPresetSuccessSchedulesOneSnapshotRefresh()
```

- [ ] **Step 2: Run `DisplayControlServiceTests` and observe RED**

Expected: preset scheduling APIs are missing.

- [ ] **Step 3: Implement one worker per display**

Add:

```swift
private var pendingPresetTargets: [CGDirectDisplayID: UInt8] = [:]
private var presetWorkers: [CGDirectDisplayID: Task<Void, Never>] = [:]
private var presetWorkerIDs: [CGDirectDisplayID: UUID] = [:]
private var desiredPresetValues: [CGDirectDisplayID: UInt8] = [:]
private var lastVerifiedPresetValues: [CGDirectDisplayID: UInt8] = [:]
```

Follow the existing contrast latest-wins worker pattern. Include preset workers in:

- `scheduleRefreshWhenIdle`;
- `seedValues(from:)`;
- `cancelPendingWrites`;
- sleep/stop/reconfiguration cancellation.

When a refreshed snapshot omits a previously active display, cancel and remove that display’s preset worker, pending target, desired value, and last verified value. A provider call already in flight may complete, but its stale worker ID must prevent publication.

- [ ] **Step 4: Run service and baseline tests**

Expected: all current and new tests pass.

- [ ] **Step 5: Review cancellation**

Ensure cancelled/old worker IDs cannot clear or overwrite newer desired preset state.

---

### Task 11: Add an Experimental Feature Gate and Menu Projection

**Files:**
- Modify: `Sources/ToolBox/DisplayControl/DisplayControlMenuModel.swift`
- Modify: `Tests/ToolBoxTests/DisplayControlMenuModelTests.swift`

**Interfaces:**
- Consumes: `DisplayControlExperimentalFeatures.colorPresetPOCEnabled`
- Produces: `DisplayControlPresetItem`
- Produces: `DisplayControlMenuModel.presetItems`
- Produces: `selectedPresetRawValue`, `presetAvailable`, `presetErrorText`

- [ ] **Step 1: Write failing menu-model tests**

Use an injected feature-enabled closure. Assert:

- disabled flag produces no visible preset items even if snapshot advertises them;
- enabled flag + available mapped capability produces options;
- unknown/unavailable capability produces no picker;
- selecting a preset immediately publishes pending selection;
- provider failure restores last verified selection and exposes concise error text;
- switching selected displays projects each display’s own options/current value.

- [ ] **Step 2: Run focused tests and observe RED**

Expected: preset menu state does not exist.

- [ ] **Step 3: Implement the model projection**

Use the feature store created in Task 7. Do not put explanatory feature marketing in the main panel. The model exposes state; the view shows the familiar control only when usable.

- [ ] **Step 4: Run menu-model tests**

Expected: all pass.

- [ ] **Step 5: Verify the flag is truly default-off**

Fresh suite/defaults must not expose or write VCP `0x14`.

For hardware POC only, document this operator-controlled enable/disable sequence in Task 13:

```bash
defaults write com.youtonghy.toolbox displayControl.experimental.colorPresetPOC -bool true
defaults delete com.youtonghy.toolbox displayControl.experimental.colorPresetPOC
```

Restart ToolBox after changing the flag. Do not add an end-user settings toggle in this POC.

---

### Task 12: Add the Compact Preset Control

**Files:**
- Modify: `Sources/ToolBox/DisplayControl/DisplayControlPanel.swift`
- Modify: `Tests/ToolBoxTests/MenuPanelLayoutTests.swift`
- Modify: `Tests/ToolBoxTests/DisplayControlMenuModelTests.swift`

**Interfaces:**
- Consumes: `presetItems`, `selectedPresetRawValue`, `presetAvailable`, `presetErrorText`
- Produces no new hardware behavior

- [ ] **Step 1: Add failing layout/model assertions**

Assert the preset row:

- is absent when unavailable/flag-off;
- appears below contrast when available;
- uses stable label/control tracks;
- can render the longest allowlisted name without overlapping the display picker or percentage columns;
- remains absent from no-display state.

- [ ] **Step 2: Run layout/model tests and observe RED**

Expected: preset row is missing.

- [ ] **Step 3: Add the SwiftUI Picker**

Use a menu-style `Picker` with the `paintpalette.fill` system symbol, label `色彩预设`, and raw `UInt8?` selection binding. Keep it in the existing unframed panel; do not add a nested card. Show a compact error line only after a failed operation.

- [ ] **Step 4: Run tests and Debug build**

```bash
xcodebuild test \
  -project ToolBox.xcodeproj \
  -scheme ToolBox \
  -configuration Debug \
  -derivedDataPath /tmp/macToolBox-display-poc-task12 \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ToolBoxTests/DisplayControlMenuModelTests \
  -only-testing:ToolBoxTests/MenuPanelLayoutTests

CONFIG=Debug OPEN=0 ./build.sh
```

- [ ] **Step 5: Perform visual QA**

Launch only when the user approves GUI execution:

```bash
OPEN=1 CONFIG=Debug ./build.sh
```

Verify no overlaps at the panel’s normal width, with one and multiple displays, flag off/on, long preset names, write-in-progress, and failure state.

---

### Task 13: Add Diagnostics and the Hardware Acceptance Log

**Files:**
- Create: `docs/testing/display-color-preset-poc-acceptance.md`
- Modify: `Sources/ToolBox/DisplayControl/Darwin/DarwinDisplayControlProvider.swift`
- Modify: `Sources/ToolBox/DisplayControl/Darwin/Arm64DDCBackend.swift`
- Modify: `Sources/ToolBox/DisplayControl/Darwin/IntelDDCBackend.swift`

**Interfaces:**
- Produces reproducible evidence for authoritative spec §12.2 Q1–Q10 and Q20
- Does not promote unverified values into the catalog

- [ ] **Step 1: Create the acceptance document**

Include one row per test observation:

```markdown
| Date | Mac/chip | macOS | Connection | Display vendor/model/serial | Firmware | Backend | Operation | Raw request | Raw reply | Result | Spec question |
```

Add explicit procedures for:

- normal Get VCP;
- unsupported Get VCP/result code;
- checksum failure injection where possible;
- Capability String multi-block read;
- non-Dell display;
- direct versus dock connection;
- `0x14` write/readback timing;
- preset side effects on brightness/contrast;
- `0xFFFF` observation.

- [ ] **Step 2: Add structured debug logs**

Log one line per capability block and preset verification attempt at debug level. Use hexadecimal formatting helpers shared by both backends; do not duplicate formatting code.

- [ ] **Step 3: Run unit tests and build**

Expected: logging additions do not change behavior.

- [ ] **Step 4: Execute available hardware checks**

Run only against displays physically connected in the environment. Never infer missing matrix cells. Mark each unrun scenario `NOT RUN`, not pass.

- [ ] **Step 5: Gate allowlist additions**

Use a two-stage gate:

**Stage A — exact-identity POC authorization.** Add an entry with raw labels (`Preset 0xXX`) only after the log contains:

- exact vendor/model/serial identity;
- complete Capability String with the value advertised;
- connection/backend details.

This authorizes controlled write/readback testing without claiming a color-space name.

**Stage B — verified friendly name.** Replace a raw label with a friendly name only when the log additionally contains:

- successful write and matching readback;
- observed preset name from the monitor/DDPM/vendor source;
- brightness/contrast side-effect result.

If no identity meets Stage A, ship the POC code default-off with an empty production catalog. If Stage A passes but Stage B does not, keep raw `Preset 0xXX` labels.

---

### Task 14: Final Verification and Scope Audit

**Files:**
- Modify: `docs/testing/display-color-preset-poc-acceptance.md` with actual results only
- Review all files from Tasks 1–13

**Interfaces:**
- Produces the final POC readiness decision

- [ ] **Step 1: Run all unit tests**

```bash
xcodebuild test \
  -project ToolBox.xcodeproj \
  -scheme ToolBox \
  -configuration Debug \
  -derivedDataPath /tmp/macToolBox-display-poc-final \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 2: Run both builds without launching**

```bash
CONFIG=Debug OPEN=0 ./build.sh
OPEN=0 ./build.sh
```

Expected: both end with `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run static diff checks**

```bash
git diff --check
git status --short
rg -n "ColorSync|maximumPotentialExtendedDynamicRange|maximumExtendedDynamicRange|0x16|0x18|0x1A|DellMonitorSdk|plawebsvc" Sources/ToolBox/DisplayControl
```

Expected: no whitespace errors. Scope scan finds no newly implemented ICC, HDR, RGB Gain, Dell SDK, or remote-download code.

- [ ] **Step 4: Audit behavior against the authoritative spec**

Confirm:

- no enum write without complete Capability String or exact allowlist fallback;
- no raw value discarded by the parser;
- no friendly name guessed for unknown identities;
- no success before readback matches;
- brightness/contrast invalidated after preset write;
- feature flag defaults off;
- disconnect/sleep/stop cancel pending work;
- no USB fallback;
- unrun §12.2 cases remain visibly unverified.

- [ ] **Step 5: Perform final code-quality review**

Check for:

- duplicated packet/checksum logic that should be shared;
- unchecked integer/index conversions;
- unbounded retry loops or capability accumulation;
- hardware operations outside the provider serial queue;
- stale tasks publishing after cancellation;
- raw capability strings or identifiers retained beyond the current display set;
- errors swallowed without user or diagnostic state.

- [ ] **Step 6: Decide the release state**

Use one:

```text
POC CODE READY / PRODUCTION CATALOG EMPTY / FEATURE DEFAULT-OFF
```

or, only after the hardware gate is met:

```text
POC READY FOR VERIFIED DISPLAY IDENTITIES / FEATURE DEFAULT-OFF
```

Do not call it formal color management until the relevant §12.2 ColorSync/HDR/RGB validation is completed and a separate plan expands the scope.

## Self-Review

- **Spec coverage:** This plan implements authoritative spec §§1–5 for Capability String and controlled `0x14`; it explicitly defers §§6–11 and ColorSync-related §12.2 items.
- **Existing changes:** Tasks 1–2 normalize the current uncommitted parsers instead of replacing them.
- **Type consistency:** Raw preset values remain `UInt8`; slider `DisplayControlKind` remains unchanged; `DDCReadOutcome` and `DDCAdvertisedSupport` remain separate.
- **Failure policy:** Parser, capability discovery, identity mapping, write authorization, and readback all fail closed.
- **Placeholders:** There are no implementation `TBD` steps. Hardware cells may be `NOT RUN`, which is an explicit evidence status rather than a placeholder.
