# DDC Write-Only Compatibility and Write Scheduling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep DDC sliders writable when Get VCP fails, remove mandatory reads from interactive writes, and ensure rapid input writes only the latest target without stale-task races.

**Architecture:** The existing provider remains the serialized hardware boundary and gains a focused value store for observed/fallback ranges and successful writes. `DisplayControlService` remains the orchestration boundary, with main-actor scheduling state and one worker per logical intent. The SwiftUI model remains declarative and treats `available` and `writeOnly` as writable states.

**Tech Stack:** Swift 5, Swift Concurrency, Combine, SwiftUI, XCTest, XcodeGen, CoreGraphics, IOKit DDC/CI.

## Global Constraints

- Keep the deployment target at macOS 14.0 and add no third-party dependency.
- Preserve the current provider -> service -> model -> view ownership split.
- Preserve Intel and Apple Silicon packet formats, two-write cycles, delays, and transport discovery.
- Do not stage, commit, revert, or rewrite unrelated existing worktree changes.
- Keep implementation changes unstaged: the existing DDC source is an untracked
  baseline, so a clean implementation-only commit cannot be constructed.
- Treat Get VCP failure with a matched transport as `writeOnly`, not as proof that Set VCP is unavailable.
- Never record failed writes as successful cached state.
- Preserve ordered mute/volume semantics.
- Use TDD for every production behavior: observe the focused test fail, implement the minimum change, then observe it pass.
- Use `CONFIG=Debug OPEN=0 ./build.sh` and `OPEN=0 ./build.sh` for final builds.

## File Map

- Modify `project.yml`: add the `ToolBoxTests` unit-test bundle.
- Modify `Sources/ToolBox/DisplayControl/DisplayControlModels.swift`: add write-only and writable-state semantics.
- Create `Sources/ToolBox/DisplayControl/Darwin/DisplayControlValueStore.swift`: own observed/fallback ranges and successful writes.
- Modify `Sources/ToolBox/DisplayControl/Darwin/DarwinDisplayControlProvider.swift`: use cached/fallback values and remove read-before-write.
- Modify `Sources/ToolBox/DisplayControl/DisplayControlService.swift`: latest-value workers, ordered volume intents, step accumulation, and debounced refresh.
- Modify `Sources/ToolBox/DisplayControl/DisplayControlMenuModel.swift`: enable write-only controls and make pending cleanup cancellation-safe.
- Modify `README.md`: document write-only compatibility and estimated initial values.
- Create `Tests/ToolBoxTests/DisplayControlCapabilityTests.swift`.
- Create `Tests/ToolBoxTests/DisplayControlValueStoreTests.swift`.
- Create `Tests/ToolBoxTests/DisplayControlServiceTests.swift`.
- Create `Tests/ToolBoxTests/DisplayControlMenuModelTests.swift`.

---

### Task 1: Add the Test Target and Write-Only Capability Semantics

**Files:**
- Modify: `project.yml`
- Modify: `Sources/ToolBox/DisplayControl/DisplayControlModels.swift`
- Modify: `Sources/ToolBox/DisplayControl/DisplayControlMenuModel.swift`
- Create: `Tests/ToolBoxTests/DisplayControlCapabilityTests.swift`

**Interfaces:**
- Produces: `DisplayControlStatus.writeOnly`
- Produces: `DisplayControlStatus.isWritable: Bool`
- Consumes: existing `DisplayControlCapability.status`

- [ ] **Step 1: Add the XCTest target and failing test**

Add this sibling target under `targets` in `project.yml`:

```yaml
  ToolBoxTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - Tests/ToolBoxTests
    dependencies:
      - target: ToolBox
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.youtonghy.toolbox.tests
        GENERATE_INFOPLIST_FILE: YES
```

Create `Tests/ToolBoxTests/DisplayControlCapabilityTests.swift`:

```swift
import XCTest
@testable import ToolBox

final class DisplayControlCapabilityTests: XCTestCase {
    func testWriteOnlyControlsRemainWritable() {
        XCTAssertTrue(DisplayControlStatus.available.isWritable)
        XCTAssertTrue(DisplayControlStatus.writeOnly.isWritable)
        XCTAssertFalse(DisplayControlStatus.unavailable.isWritable)
        XCTAssertFalse(DisplayControlStatus.unsupported.isWritable)
    }
}
```

- [ ] **Step 2: Generate the project and verify RED**

Run:

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' -only-testing:ToolBoxTests/DisplayControlCapabilityTests
```

Expected: compilation fails because `writeOnly` and `isWritable` do not exist.

- [ ] **Step 3: Implement the minimum status model**

Change `DisplayControlStatus` to:

```swift
enum DisplayControlStatus: String, Codable, Equatable, Sendable {
    case available
    case writeOnly
    case unsupported
    case unavailable

    var isWritable: Bool {
        self == .available || self == .writeOnly
    }
}
```

Update menu-model enablement:

```swift
isEnabled: capability.status.isWritable && kind.isContinuous
muteAvailable = muteCapability?.status.isWritable == true
```

- [ ] **Step 4: Verify GREEN and Debug build**

Run:

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' -only-testing:ToolBoxTests/DisplayControlCapabilityTests
CONFIG=Debug OPEN=0 ./build.sh
```

Expected: one test passes and the build ends with `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Record the Task 1 checkpoint without staging**

```bash
git diff --check
git status --short
```

Expected: diff check is empty and no file is staged.

### Task 2: Add Fallback Value State and Remove Read-Before-Write

**Files:**
- Create: `Sources/ToolBox/DisplayControl/Darwin/DisplayControlValueStore.swift`
- Modify: `Sources/ToolBox/DisplayControl/Darwin/DarwinDisplayControlProvider.swift`
- Create: `Tests/ToolBoxTests/DisplayControlValueStoreTests.swift`

**Interfaces:**
- Consumes: `DisplayControlStatus.writeOnly`
- Produces: `DisplayControlValueKey(displayID:kind:)`
- Produces: `DisplayControlValueStore.value(for:)`
- Produces: `DisplayControlValueStore.capability(for:observedValue:)`
- Produces: `recordObserved`, `rawValue`, `shouldWrite`, and `recordSuccessfulWrite`

- [ ] **Step 1: Write failing value-store tests**

Create `Tests/ToolBoxTests/DisplayControlValueStoreTests.swift`:

```swift
import CoreGraphics
import XCTest
@testable import ToolBox

final class DisplayControlValueStoreTests: XCTestCase {
    private let displayID: CGDirectDisplayID = 42

    func testFallbacksMatchWriteOnlyDefaults() {
        let store = DisplayControlValueStore()
        XCTAssertEqual(store.value(for: .init(displayID: displayID, kind: .brightness)).rawCurrent, 100)
        XCTAssertEqual(store.value(for: .init(displayID: displayID, kind: .contrast)).rawCurrent, 75)
        XCTAssertEqual(store.value(for: .init(displayID: displayID, kind: .volume)).rawCurrent, 12)
        XCTAssertEqual(store.value(for: .init(displayID: displayID, kind: .mute)).rawCurrent, 2)
    }

    func testObservedRangeControlsRawConversion() throws {
        var store = DisplayControlValueStore()
        let key = DisplayControlValueKey(displayID: displayID, kind: .brightness)
        store.recordObserved(
            DisplayControlValue(
                kind: .brightness,
                timestamp: Date(),
                rawCurrent: 20,
                rawMinimum: 0,
                rawMaximum: 80,
                normalized: 0.25
            ),
            for: key
        )
        XCTAssertEqual(try store.rawValue(for: key, normalized: 0.5), 40)
    }

    func testMissingObservationProducesWritableFallbackCapability() {
        var store = DisplayControlValueStore()
        let key = DisplayControlValueKey(displayID: displayID, kind: .brightness)
        let capability = store.capability(for: key, observedValue: nil)
        XCTAssertEqual(capability.status, .writeOnly)
        XCTAssertEqual(capability.value?.rawCurrent, 100)
    }

    func testSuccessfulWriteUpdatesDeduplicationState() throws {
        var store = DisplayControlValueStore()
        let key = DisplayControlValueKey(displayID: displayID, kind: .brightness)
        let raw = try store.rawValue(for: key, normalized: 0.4)
        XCTAssertTrue(store.shouldWrite(raw, for: key))
        store.recordSuccessfulWrite(raw, normalized: 0.4, for: key)
        XCTAssertFalse(store.shouldWrite(raw, for: key))
        XCTAssertEqual(store.value(for: key).normalized, 0.4, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Verify RED**

Run:

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' -only-testing:ToolBoxTests/DisplayControlValueStoreTests
```

Expected: compilation fails because the value-store types do not exist.

- [ ] **Step 3: Implement the focused value store**

Create `DisplayControlValueStore.swift` with this module interface and behavior:

```swift
import CoreGraphics
import Foundation

struct DisplayControlValueKey: Hashable, Sendable {
    var displayID: CGDirectDisplayID
    var kind: DisplayControlKind
}

struct DisplayControlValueStore {
    private var values: [DisplayControlValueKey: DisplayControlValue] = [:]
    private var lastSuccessfulRawValues: [DisplayControlValueKey: UInt16] = [:]

    func value(for key: DisplayControlValueKey) -> DisplayControlValue {
        values[key] ?? Self.fallbackValue(kind: key.kind)
    }

    mutating func recordObserved(_ value: DisplayControlValue, for key: DisplayControlValueKey) {
        values[key] = value
    }

    mutating func capability(
        for key: DisplayControlValueKey,
        observedValue: DisplayControlValue?
    ) -> DisplayControlCapability {
        if let observedValue {
            recordObserved(observedValue, for: key)
            return DisplayControlCapability(
                kind: key.kind,
                status: .available,
                value: observedValue,
                unavailableReason: nil
            )
        }
        return DisplayControlCapability(
            kind: key.kind,
            status: .writeOnly,
            value: value(for: key),
            unavailableReason: "Current value unavailable; DDC writes remain enabled."
        )
    }

    func rawValue(for key: DisplayControlValueKey, normalized: Double) throws -> UInt16 {
        guard normalized.isFinite, (0...1).contains(normalized) else {
            throw DisplayControlError.invalidValue(normalized)
        }
        if key.kind == .mute { return normalized >= 0.5 ? 1 : 2 }
        let current = value(for: key)
        guard current.rawMaximum > current.rawMinimum else {
            throw DisplayControlError.invalidRange(
                minimum: current.rawMinimum,
                maximum: current.rawMaximum
            )
        }
        let span = Double(current.rawMaximum - current.rawMinimum)
        let raw = Double(current.rawMinimum) + span * normalized
        return UInt16(min(max(raw.rounded(), Double(current.rawMinimum)), Double(current.rawMaximum)))
    }

    func shouldWrite(_ rawValue: UInt16, for key: DisplayControlValueKey) -> Bool {
        lastSuccessfulRawValues[key] != rawValue
    }

    mutating func recordSuccessfulWrite(
        _ rawValue: UInt16,
        normalized: Double,
        for key: DisplayControlValueKey
    ) {
        var value = value(for: key)
        value.timestamp = Date()
        value.rawCurrent = rawValue
        value.normalized = normalized
        values[key] = value
        lastSuccessfulRawValues[key] = rawValue
    }

    mutating func retainDisplays(_ displayIDs: Set<CGDirectDisplayID>) {
        values = values.filter { displayIDs.contains($0.key.displayID) }
        lastSuccessfulRawValues = lastSuccessfulRawValues.filter { displayIDs.contains($0.key.displayID) }
    }

    private static func fallbackValue(kind: DisplayControlKind) -> DisplayControlValue {
        let tuple: (current: UInt16, maximum: UInt16) = switch kind {
        case .brightness: (100, 100)
        case .contrast: (75, 100)
        case .volume: (12, 100)
        case .mute: (2, 2)
        }
        return DisplayControlValue(
            kind: kind,
            timestamp: Date(),
            rawCurrent: tuple.current,
            rawMinimum: 0,
            rawMaximum: tuple.maximum,
            normalized: kind == .mute ? 0 : Double(tuple.current) / Double(tuple.maximum)
        )
    }
}
```

If Swift 5 rejects the switch expression, use a normal `switch` that assigns
`current` and `maximum`; do not change the values or interface.

- [ ] **Step 4: Integrate snapshot fallback**

Replace provider `lastWrites` with `private var valueStore = DisplayControlValueStore()`.
In `makeCapabilityLocked`, after confirming the transport exists, use:

```swift
let key = DisplayControlValueKey(displayID: displayID, kind: kind)
let observedValue = try? currentValueLocked(
    displayID: displayID,
    kind: kind,
    transport: transport,
    options: .probe
)
return valueStore.capability(for: key, observedValue: observedValue)
```

After replacing transports, call `valueStore.retainDisplays(Set(nextTransports.keys))`.

- [ ] **Step 5: Remove interactive read-before-write**

Replace the read/convert/write core of `writeValue` with:

```swift
let key = DisplayControlValueKey(displayID: displayID, kind: kind)
let rawValue = try self.valueStore.rawValue(for: key, normalized: normalizedValue)
if self.valueStore.shouldWrite(rawValue, for: key) {
    guard transport.write(command: kind.ddcCommand.rawValue, value: rawValue, options: .interactive) else {
        throw DisplayControlError.writeFailed(displayID, kind)
    }
    self.valueStore.recordSuccessfulWrite(rawValue, normalized: normalizedValue, for: key)
}
return self.valueStore.value(for: key)
```

Keep `currentValueLocked` only for explicit reads and snapshot probes.

- [ ] **Step 6: Verify GREEN and source constraint**

Run:

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' -only-testing:ToolBoxTests/DisplayControlValueStoreTests
rg -n "currentValueLocked" Sources/ToolBox/DisplayControl/Darwin/DarwinDisplayControlProvider.swift
CONFIG=Debug OPEN=0 ./build.sh
```

Expected: tests pass; `currentValueLocked` is absent from `writeValue`; Debug build succeeds.

- [ ] **Step 7: Record the Task 2 checkpoint without staging**

```bash
git diff --check
git status --short
```

Expected: diff check is empty and no file is staged.

### Task 3: Coalesce Writes and Keep One Brightness Worker

**Files:**
- Modify: `Sources/ToolBox/DisplayControl/DisplayControlService.swift`
- Create: `Tests/ToolBoxTests/DisplayControlServiceTests.swift`

**Interfaces:**
- Consumes: existing `DisplayControlProviding`
- Produces: `DisplayControlTiming.live` and `.immediateForTests`
- Preserves: `writeBrightness`, `writeControl`, `setVolume`, and `stepValue` call sites
- Internal state: one worker for each brightness display, direct-control key, and volume display

- [ ] **Step 1: Write the blocking fake and failing burst tests**

Create `Tests/ToolBoxTests/DisplayControlServiceTests.swift`:

```swift
import CoreGraphics
import XCTest
@testable import ToolBox

actor RecordingDisplayControlProvider: DisplayControlProviding {
    private(set) var writes: [(DisplayControlKind, Double)] = []
    private var firstWriteContinuation: CheckedContinuation<Void, Never>?
    private var shouldBlockFirstWrite = false
    private let configuredSnapshot: DisplayControlSnapshot

    init(
        snapshot: DisplayControlSnapshot = DisplayControlSnapshot(
            timestamp: Date(),
            displays: []
        )
    ) {
        configuredSnapshot = snapshot
    }

    func blockFirstWrite() { shouldBlockFirstWrite = true }
    func releaseFirstWrite() {
        firstWriteContinuation?.resume()
        firstWriteContinuation = nil
    }
    func recordedWrites() -> [(DisplayControlKind, Double)] { writes }
    func snapshot() async throws -> DisplayControlSnapshot {
        configuredSnapshot
    }
    func refresh() async throws {}
    func readValue(displayID: CGDirectDisplayID, kind: DisplayControlKind) async throws -> DisplayControlValue {
        throw DisplayControlError.readFailed(displayID, kind)
    }
    func writeValue(
        displayID: CGDirectDisplayID,
        kind: DisplayControlKind,
        normalizedValue: Double
    ) async throws -> DisplayControlValue {
        writes.append((kind, normalizedValue))
        if shouldBlockFirstWrite && writes.count == 1 {
            await withCheckedContinuation { firstWriteContinuation = $0 }
        }
        return DisplayControlValue(
            kind: kind,
            timestamp: Date(),
            rawCurrent: UInt16((normalizedValue * 100).rounded()),
            rawMinimum: 0,
            rawMaximum: 100,
            normalized: normalizedValue
        )
    }
}

@MainActor
final class DisplayControlServiceTests: XCTestCase {
    func testContrastBurstKeepsOnlyInFlightAndLatest() async {
        let provider = RecordingDisplayControlProvider()
        await provider.blockFirstWrite()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.writeControl(displayID: 42, kind: .contrast, normalizedValue: 0.2)
        await Task.yield()
        service.writeControl(displayID: 42, kind: .contrast, normalizedValue: 0.4)
        service.writeControl(displayID: 42, kind: .contrast, normalizedValue: 0.8)
        await provider.releaseFirstWrite()
        await service.waitForPendingWritesForTesting()
        let values = await provider.recordedWrites().map(\.1)
        XCTAssertEqual(values, [0.2, 0.8])
    }

    func testWriteOnlyBrightnessConvergesOnLatestDirectTarget() async {
        let provider = RecordingDisplayControlProvider()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.writeBrightness(displayID: 42, normalizedValue: 0.3)
        service.writeBrightness(displayID: 42, normalizedValue: 0.7)
        await service.waitForPendingWritesForTesting()
        let values = await provider.recordedWrites().filter { $0.0 == .brightness }.map(\.1)
        XCTAssertEqual(values.last, 0.7)
        XCTAssertLessThanOrEqual(values.count, 2)
    }

    func testPositiveVolumeWritesUnmuteThenLatestVolume() async {
        let provider = RecordingDisplayControlProvider()
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        service.setVolume(displayID: 42, normalizedValue: 0.2)
        service.setVolume(displayID: 42, normalizedValue: 0.6)
        await service.waitForPendingWritesForTesting()
        let writes = await provider.recordedWrites()
        XCTAssertEqual(writes.suffix(2).map(\.0), [.mute, .volume])
        XCTAssertEqual(writes.last?.1, 0.6)
    }
}
```

- [ ] **Step 2: Verify RED**

Run:

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' -only-testing:ToolBoxTests/DisplayControlServiceTests
```

Expected: compilation fails because timing, coalescing, and the test wait do not exist.

- [ ] **Step 3: Isolate scheduler state on the main actor**

Annotate `DisplayControlService` with `@MainActor`, add a `timing` property, and
use this configuration:

```swift
struct DisplayControlTiming {
    var brightnessFrameDelayNanos: UInt64
    var refreshDebounceNanos: UInt64

    static let live = DisplayControlTiming(
        brightnessFrameDelayNanos: 20_000_000,
        refreshDebounceNanos: 250_000_000
    )
    static let immediateForTests = DisplayControlTiming(
        brightnessFrameDelayNanos: 0,
        refreshDebounceNanos: 0
    )
}

init(
    provider: DisplayControlProviding = DarwinDisplayControlProvider(),
    timing: DisplayControlTiming = .live
) {
    self.provider = provider
    self.timing = timing
}
```

Enter main-actor isolation from the C display callback:

```swift
let service = Unmanaged<DisplayControlService>.fromOpaque(userInfo).takeUnretainedValue()
Task { @MainActor in service.handleDisplayReconfiguration() }
```

- [ ] **Step 4: Implement one dynamic-target brightness worker**

Replace cancel-and-recreate state with:

```swift
private var latestBrightnessTargets: [CGDirectDisplayID: Double] = [:]
private var lastSuccessfulBrightness: [CGDirectDisplayID: Double] = [:]
private var brightnessWorkers: [CGDirectDisplayID: Task<Void, Never>] = [:]
```

`writeBrightness` only updates the target and creates a worker when absent:

```swift
func writeBrightness(displayID: CGDirectDisplayID, normalizedValue: Double, smooth: Bool = true) {
    latestBrightnessTargets[displayID] = Self.clamp(normalizedValue)
    guard brightnessWorkers[displayID] == nil else { return }
    brightnessWorkers[displayID] = Task { [weak self] in
        await self?.runBrightnessWorker(displayID: displayID, smooth: smooth)
    }
}
```

`runBrightnessWorker` re-reads the latest target after each awaited write. It
uses an `.available` brightness value from `snapshot` as a trusted initial value.
When the snapshot status is `.writeOnly` and no prior app write exists, it writes
the target directly; otherwise it uses the existing distance/6 and minimum 0.01
step. It updates
`lastSuccessfulBrightness` only after provider success, continues if the target
changed, and returns on cancellation before cleanup. Only the active worker may
clear its slot. Sleep through `timing.brightnessFrameDelayNanos`.

- [ ] **Step 5: Implement direct-control and ordered volume drains**

Add:

```swift
private struct ControlWriteKey: Hashable {
    var displayID: CGDirectDisplayID
    var kind: DisplayControlKind
}
private var pendingControlTargets: [ControlWriteKey: Double] = [:]
private var controlWorkers: [ControlWriteKey: Task<Void, Never>] = [:]
private var pendingVolumeTargets: [CGDirectDisplayID: Double] = [:]
private var volumeWorkers: [CGDirectDisplayID: Task<Void, Never>] = [:]
```

Each drain takes one pending target, awaits it, then consumes only the latest
replacement. For volume, each consumed intent executes exactly:

```swift
if target <= 0 {
    _ = try await provider.writeValue(displayID: displayID, kind: .volume, normalizedValue: 0)
    _ = try await provider.writeValue(displayID: displayID, kind: .mute, normalizedValue: 1)
} else {
    _ = try await provider.writeValue(displayID: displayID, kind: .mute, normalizedValue: 0)
    _ = try await provider.writeValue(displayID: displayID, kind: .volume, normalizedValue: target)
}
```

Remove per-intermediate `refresh()` calls. Schedule one refresh after a worker
becomes idle using `timing.refreshDebounceNanos`; cancellation must return without
clearing a newer refresh task.

Replace `cancelSmoothBrightnessTasks` with one cancellation method that cancels
brightness, direct-control, volume, and refresh workers, then clears all pending
targets. Call it from both `stop()` and sleep suspension. Each worker catches and
logs provider errors, clears only its own active slot, and leaves failed values
out of last-successful state so the next user action can retry.

- [ ] **Step 6: Accumulate steps without hardware reads**

Change `stepValue` to choose its baseline from latest pending target, last
successful target, then snapshot capability value. Clamp baseline plus delta and
submit through brightness, volume, or direct-control workers. Remove
`provider.readValue` from key-repeat paths.

- [ ] **Step 7: Add deterministic test waiting**

Add this internal `@testable` helper:

```swift
func waitForPendingWritesForTesting() async {
    while !brightnessWorkers.isEmpty || !controlWorkers.isEmpty || !volumeWorkers.isEmpty {
        await Task.yield()
    }
}
```

- [ ] **Step 8: Verify GREEN and source constraints**

Run:

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' -only-testing:ToolBoxTests/DisplayControlServiceTests
rg -n "provider\.readValue" Sources/ToolBox/DisplayControl/DisplayControlService.swift
CONFIG=Debug OPEN=0 ./build.sh
```

Expected: scheduler tests pass, step paths contain no provider read, and Debug build succeeds.

- [ ] **Step 9: Record the Task 3 checkpoint without staging**

```bash
git diff --check
git status --short
```

Expected: diff check is empty and no file is staged.

### Task 4: Fix Optimistic UI Ownership, Document, and Verify End to End

**Files:**
- Modify: `Sources/ToolBox/DisplayControl/DisplayControlMenuModel.swift`
- Create: `Tests/ToolBoxTests/DisplayControlMenuModelTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: `DisplayControlStatus.isWritable`
- Consumes: scheduler and `RecordingDisplayControlProvider` from Task 3
- Produces: cancellation-safe optimistic slider state

- [ ] **Step 1: Write the failing pending-state test**

Create `Tests/ToolBoxTests/DisplayControlMenuModelTests.swift`:

```swift
import Combine
import XCTest
@testable import ToolBox

@MainActor
final class DisplayControlMenuModelTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    func testCancelledPendingClearCannotRemoveReplacementValue() async {
        let capability = DisplayControlCapability(
            kind: .brightness,
            status: .writeOnly,
            value: DisplayControlValue(
                kind: .brightness,
                timestamp: Date(),
                rawCurrent: 50,
                rawMinimum: 0,
                rawMaximum: 100,
                normalized: 0.5
            ),
            unavailableReason: nil
        )
        let display = DisplayControlDisplay(
            id: 42,
            name: "Test Display",
            vendorNumber: nil,
            modelNumber: nil,
            serialNumber: nil,
            isBuiltIn: false,
            isVirtual: false,
            supportsHardwareDDC: true,
            backendName: "Fake DDC",
            unavailableReason: nil,
            controls: [capability]
        )
        let provider = RecordingDisplayControlProvider(
            snapshot: DisplayControlSnapshot(timestamp: Date(), displays: [display])
        )
        let service = DisplayControlService(provider: provider, timing: .immediateForTests)
        let refreshed = expectation(description: "snapshot refreshed")
        service.$snapshot.dropFirst().first().sink { _ in refreshed.fulfill() }.store(in: &cancellables)
        service.refresh()
        await fulfillment(of: [refreshed], timeout: 1)

        let model = DisplayControlMenuModel(
            service: service,
            pendingValueLifetimeNanos: 1_000_000_000
        )
        model.start()
        model.setValue(kind: .brightness, value: 0.3)
        model.setValue(kind: .brightness, value: 0.7)
        await Task.yield()

        XCTAssertEqual(
            model.sliderItems.first(where: { $0.kind == .brightness })?.value,
            0.7
        )
    }
}
```

- [ ] **Step 2: Verify RED**

Run:

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' -only-testing:ToolBoxTests/DisplayControlMenuModelTests
```

Expected: compilation fails because configurable pending lifetime does not exist, or the assertion fails because the cancelled predecessor clears the replacement.

- [ ] **Step 3: Make pending cleanup cancellation- and ownership-safe**

Extend the initializer:

```swift
init(
    service: DisplayControlService = .shared,
    pendingValueLifetimeNanos: UInt64 = 750_000_000
) {
    self.service = service
    self.pendingValueLifetimeNanos = pendingValueLifetimeNanos
}
```

Add generations:

```swift
private var pendingGenerations: [DisplayControlPendingKey: UInt64] = [:]
```

When setting a pending value, increment and capture its generation. Replace the
current `try? Task.sleep` cleanup with:

```swift
do {
    try await Task.sleep(nanoseconds: pendingValueLifetimeNanos)
} catch is CancellationError {
    return
} catch {
    return
}
guard !Task.isCancelled else { return }
await MainActor.run {
    guard self.pendingGenerations[key] == generation else { return }
    self.pendingValues[key] = nil
    self.pendingClearTasks[key] = nil
    self.pendingGenerations[key] = nil
    self.ingest(self.service.snapshot)
}
```

Clear `pendingGenerations` in `stop()`.

- [ ] **Step 4: Add write-only UI copy and README note**

When any selected capability is `.writeOnly`, show:

```swift
statusText = "DDC write-only · current values estimated"
```

Add this near the existing README DDC compatibility note:

```markdown
- **DDC 只写兼容**：若外接显示器可匹配硬件 DDC transport、但 Get VCP
  读取失败，ToolBox 仍允许发送 Set VCP。首次显示的百分比是保守估算值；
  成功写入后显示本应用最后一次写入的值。
```

- [ ] **Step 5: Verify all tests and diff hygiene**

Run:

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' -only-testing:ToolBoxTests
git diff --check
```

Expected: all tests pass with zero failures; diff check prints no output.

- [ ] **Step 6: Run canonical Debug and Release builds**

Run:

```bash
CONFIG=Debug OPEN=0 ./build.sh
OPEN=0 ./build.sh
```

Expected: both builds end with `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Perform the final code-quality review**

Confirm the final diff has no mandatory Get VCP in interactive writes, one owner
per worker slot, explicit cancellation exits, successful-write-only caching,
preserved volume ordering, no unbounded retry, and no unrelated staged file.

Run separately:

```bash
git diff -- Sources/ToolBox/DisplayControl Tests/ToolBoxTests project.yml README.md
```

```bash
git status --short
```

- [ ] **Step 8: Record the final unstaged implementation state**

```bash
git diff --check
git status --short
```

Expected: diff check is empty and all implementation/test/doc changes remain
unstaged for explicit user review.

- [ ] **Step 9: Hardware smoke test on the Dell U2723QE**

Launch the freshly built app and verify:

1. The display reports `DDC/CI over IOAVService`.
2. Brightness, contrast, volume, and mute controls are enabled in write-only mode.
3. Each control changes the physical monitor.
4. Rapid brightness movement converges to the final slider position.
5. No previous value is replayed after input stops.
6. Media-key repeats accumulate in the expected direction.

Expected: all six checks pass. If one VCP command is ignored while others work,
report it as monitor-specific instead of disabling every control or changing
transport timing without new evidence.
