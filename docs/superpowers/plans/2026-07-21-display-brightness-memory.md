# Display Brightness Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the last known brightness after a write-only DDC display reconnects without replacing authoritative hardware reads.

**Architecture:** Add a focused, versioned `UserDefaults` store keyed by stable vendor/model/serial identity. The existing Darwin provider supplies that identity to `DisplayControlValueStore`, which keeps hardware observations authoritative and uses memory only for write-only fallback.

**Tech Stack:** Swift 5, Foundation `UserDefaults` and `Codable`, CoreGraphics, OSLog, XCTest, XcodeGen.

## Global Constraints

- Keep macOS deployment target 14.0 and add no dependency.
- Preserve provider -> service -> model -> view ownership.
- Persist only displays with vendor, model, and serial numbers.
- Never let persistence failure disable DDC reads or writes.
- Preserve unrelated dirty worktree changes.

---

### Task 1: Add Versioned Brightness Memory

**Files:**
- Create: `Sources/ToolBox/DisplayControl/Darwin/DisplayBrightnessMemoryStore.swift`
- Create: `Tests/ToolBoxTests/DisplayBrightnessMemoryStoreTests.swift`

**Interfaces:**
- Produces: `DisplayBrightnessMemoryIdentity(vendorNumber:modelNumber:serialNumber:)`
- Produces: `DisplayBrightnessMemoryStore.load(identity:) -> Double?`
- Produces: `DisplayBrightnessMemoryStore.save(_:identity:)`

- [x] Write tests for missing data, round trip, corrupt JSON, unknown schema, and invalid values.
- [x] Run the focused test and confirm RED because the types do not exist.
- [x] Implement a versioned Codable document stored as `Data` in `UserDefaults`, with OSLog diagnostics and range validation.
- [x] Run the focused test and confirm GREEN.

### Task 2: Restore Memory Only for Write-Only Brightness

**Files:**
- Modify: `Sources/ToolBox/DisplayControl/Darwin/DisplayControlValueStore.swift`
- Modify: `Sources/ToolBox/DisplayControl/Darwin/DarwinDisplayControlProvider.swift`
- Modify: `Tests/ToolBoxTests/DisplayControlValueStoreTests.swift`

**Interfaces:**
- `capability(for:identity:observedValue:)` records an observed brightness, otherwise restores remembered brightness.
- `recordSuccessfulWrite(_:normalized:for:identity:)` persists successful brightness writes only.

- [x] Add tests proving restoration across different `CGDirectDisplayID` values and hardware observation precedence.
- [x] Run the focused tests and confirm RED on the missing identity-aware interface.
- [x] Inject the memory store into the value store, add stable identity creation in the provider, and wire successful reads/writes.
- [x] Run all display-control tests and confirm GREEN.

### Task 3: Document and Verify

**Files:**
- Modify: `README.md`

- [x] Explain that write-only brightness restores the last known value for displays with stable serial identity.
- [x] Run the full test target.
- [x] Run `CONFIG=Debug OPEN=0 ./build.sh` and `OPEN=0 ./build.sh`.
- [x] Run codesign verification and `git diff --check`.
- [x] Review the final diff for persistence safety, collisions, performance, and unrelated changes.
