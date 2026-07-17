# Scheduled External-Display Brightness Implementation Plan

## Plan status

This is an implementation plan only. It reflects the current worktree, including existing uncommitted changes in `AppDelegate.swift`, `SettingsView.swift`, and display-control files. Implementation must preserve and build on those changes.

### Locked product decisions

| Decision | v1 default | Rationale |
|---|---|---|
| Target scope | All currently controllable external displays | Predictable, survives display-ID changes, and does not invent stable identity for serial-less displays. |
| Manual override | Per display until the next scheduled boundary | Slider/media-key changes take effect without disabling the schedule or changing other displays. |
| Duplicate writes | Force all schedule applications | Launch, boundary, wake, and reconfiguration writes bypass the write-only raw-value cache. Manual writes keep current deduplication. |
| Transition style | Discrete | Schedule calls `writeBrightness` with `smooth: false`; manual controls keep smooth behavior. |
| Editor model | Freeform cyclic change points | Persist starts and derive ends, enforcing full-day coverage by construction. |
| Time basis | Current macOS local time zone | Store no zone and expose no zone selector in v1. |
| Controlled property | Brightness only | Contrast, volume, mute, and color controls are out of scope. |
| Launch behavior | Apply active segment when the first eligible snapshot is available | Panel and Settings do not need to open. |
| Launch at login | Recommended, never required | Schedule enablement is never blocked. |
| UI language | Chinese | All new visible, validation, state, tooltip, and accessibility text is Chinese. |
| Sleep/wake | Re-apply on the first fresh post-wake snapshot | Avoid exposing private `DisplayControlService.isSuspended` initially. |
| Missing serial | Not persistently identifiable | Never synthesize identity from vendor/model/name; target all eligible current IDs. |

## 1. Goals and non-goals

### Goals

1. Create, edit, and persist freeform brightness segments representing exactly one local wall-clock day.
2. Support ordinary and wrap intervals such as `22:00-07:00` without contradictory stored endpoints.
3. While the LSUIElement process runs, apply the active segment to every external, non-virtual display with writable DDC brightness.
4. Run independently of the panel and Settings window.
5. Apply on enable, launch, current configuration changes, display arrival/replug, relevant clock changes, and wake refresh.
6. Make conflict behavior explicit: a manual brightness change overrides only that display until the next boundary.
7. Force schedule writes through the existing DDC path so monitor reset/write-only cache cannot suppress re-application.
8. Hide validation, persistence, local-time evaluation, timers, topology filtering, and override expiry behind a small coordinator interface.
9. Add Chinese controls under Settings > `显示器`, matching current glass chrome and editable without a connected display.
10. Build deterministic unit coverage before lifecycle/UI wiring.

### Non-goals

1. Running while ToolBox is not running; there is no daemon/helper in v1.
2. Requiring launch at login.
3. Built-in/virtual display control or a non-DDC path.
4. Per-display or selected-display schedules, persisted pinning, or override transfer after replug.
5. Contrast, volume, mute, input source, color temperature, HDR, or power schedules.
6. Sunrise/sunset, location, weekday profiles, calendar rules, or cloud sync.
7. Smooth ramps, transition duration, interpolation, or replay of all missed boundaries.
8. Independent end-time editing; ends are derived to preserve coverage.
9. A time-zone selector.
10. Claiming hardware confirmation from write-only monitors. UI reports requested state, not verified state.

## 2. Domain model

### Module and types

Create `Sources/ToolBox/DisplayControl/Schedule/BrightnessSchedule.swift` as a pure module. Callers must not sort raw arrays or perform cyclic minute arithmetic.

- `MinuteOfDay`: `RawRepresentable`, `Codable`, `Hashable`, `Comparable`, `Sendable`; raw value `0..<1440`. Convert to/from local hour/minute components, never persisted absolute dates.
- `BrightnessScheduleSegment`: `Identifiable`, `Codable`, `Equatable`, `Sendable`; stable `UUID id`, `MinuteOfDay startMinute`, integer `brightnessPercent` in `0...100`.
- `BrightnessSchedule`: validated, canonical, non-empty cyclic sequence sorted by start, with no mutable storage exposed.
- `BrightnessScheduleInterval`: derived ID, start, end, duration, brightness, and `wrapsToNextDay`.
- `BrightnessScheduleMatch`: active segment and next absolute schedule transition.
- `BrightnessScheduleValidationError`: empty, invalid minute/brightness, duplicate ID/start, and internal coverage failure.
- `BrightnessScheduleConfiguration`: `isEnabled` and one validated schedule. Scope, zone, transitions, and conflict policy are fixed v1 behavior, not settings.

Required pure operations:

- `BrightnessSchedule(validating segments:)` validates/canonicalizes decoded and edited data.
- `intervals` returns complete cyclic intervals.
- `match(at:calendar:)` returns the active segment and next boundary.
- `insertingSegment(startMinute:brightnessPercent:)`, `updatingSegment(id:startMinute:brightnessPercent:)`, and `removingSegment(id:)` return a validated copy or throw.
- `suggestedInsertion(after:)` returns an unused midpoint minute when possible.

Formatting and Chinese messages stay outside the domain. Tests inject fixed calendars/zones without changing globals.

### Invariants

1. Segment count is `1...1440`, the natural one-minute limit.
2. IDs are unique.
3. Start minutes are valid and unique.
4. Brightness is integer `0...100`.
5. Storage is canonical ascending start order; input order has no meaning.
6. Intervals are half-open `[start, nextStart)`; exact boundary selects the new segment.
7. Multiple-segment durations are positive. One segment is exactly 1,440 minutes and displays `全天`.
8. The last segment ends at the first start on the next day.
9. Invalid intermediate drafts are neither published nor persisted.

### Complete 24-hour coverage algorithm

For starts `s[0] < ... < s[n-1]`:

1. If `n == 1`, derive one 1,440-minute interval.
2. Otherwise, `end = s[(i + 1) mod n]` and `duration = (end - s[i] + 1440) mod 1440`.
3. Reject zero durations; unique starts make all positive.
4. Assert total duration is 1,440. Non-wrap durations telescope and the final modular duration closes the day.
5. For local minute `m`, choose greatest start `<= m`; if none, choose the last segment. Every minute matches exactly one interval.

Starts `07:00=80`, `09:00=60`, `18:00=70`, `22:00=35` derive `07:00-09:00`, `09:00-18:00`, `18:00-22:00`, `22:00-次日 07:00`. No separate end can introduce a gap/overlap.

### Local time and DST

1. Use a fresh `Calendar.autoupdatingCurrent` per reconciliation; never cache/persist its zone.
2. Active matching uses local hour/minute.
3. For each start, call `Calendar.nextDate(after:matching:matchingPolicy:repeatedTimePolicy:direction:)` with `.nextTime` and both `.first`/`.last`; deduplicate equal dates and choose the earliest future occurrence.
4. A spring-forward missing time applies at the first valid time after the gap.
5. Fall-back uses literal wall-clock semantics: a repeated boundary may occur in both occurrences. At offset rollback, reevaluation may return to the preceding segment until the boundary repeats.
6. Schedule runtime reconciliation at the earlier of next configured boundary and `TimeZone.nextDaylightSavingTimeTransition(after:)`. The DST transition is an internal correctness wakeup, not the UI's next-segment time.
7. Also reevaluate on `NSSystemClockDidChangeNotification`, `NSSystemTimeZoneDidChangeNotification`, and `NSCalendarDayChangedNotification`.
8. After sleep/clock jump, apply only the current segment; do not replay history.

## 3. Persistence

Create `Sources/ToolBox/DisplayControl/Schedule/BrightnessScheduleStore.swift`.

### Format

- One `UserDefaults` `Data` value at `display.brightnessSchedule.v1`.
- `BrightnessScheduleDocumentV1` contains `schemaVersion: 1`, `isEnabled`, canonical segments.
- Persist stable segment UUIDs.
- Do not persist display identity/ID, zone, next-fire date, runtime state, last values, or overrides.
- Deterministic JSON makes one debuggable atomic blob.

### Interface and behavior

Expose only `load() -> BrightnessScheduleLoadResult` and `save(_ configuration:) throws`. Inject `UserDefaults`/key for isolated tests; do not introduce a one-adapter persistence protocol.

1. Missing key returns disabled.
2. Editable default is `07:00=80%`, `09:00=60%`, `18:00=70%`, `22:00=35%`.
3. Validate schema, then reconstruct through `BrightnessSchedule(validating:)`; decoding never bypasses invariants.
4. Corrupt/unknown/invalid data fails closed: disabled in memory, original bytes retained until valid commit, issue logged and exposed nonfatally in Settings.
5. Publish coordinator configuration only after encode/`UserDefaults.set`; failed commits retain prior configuration/timer.

No migration from `@AppStorage` is needed because no schedule key exists. Future formats require explicit migration.

## 4. Runtime coordinator

### Deep module interface

Create `Sources/ToolBox/DisplayControl/Schedule/BrightnessScheduleCoordinator.swift` as `@MainActor ObservableObject`, exposing only:

- `@Published private(set) configuration: BrightnessScheduleConfiguration`
- `@Published private(set) runtimeState: BrightnessScheduleRuntimeState`
- `@Published private(set) configurationIssue: BrightnessScheduleConfigurationIssue?`
- `start()`, `stop()`, `commit(_ configuration:) throws`

It owns store, snapshot/manual subscriptions, one runtime timer, notifications, target signatures, wake state, and overrides. All calculations remain private.

`BrightnessScheduleRuntimeState` is data, not English strings: disabled, waiting, active target/count/next transition, active-with-overrides. Settings localizes it.

### Clock seam

Create `Sources/ToolBox/DisplayControl/Schedule/BrightnessScheduleClock.swift` with internal `BrightnessScheduleClock` supplying `now`, local calendar/time zone, and one-shot schedule-at-date.

- `FoundationBrightnessScheduleClock`: main-run-loop common-mode one-shot `Timer`, tolerance at most one second.
- `TestBrightnessScheduleClock`: records fire date and fires only when tests advance it.

Cancel/replace prior timer, choosing earlier of next segment/DST offset transition. Generation-check callbacks so cancellation is authoritative.

### Eligible targets and identity

A target must satisfy all:

1. `isBuiltIn == false`.
2. `isVirtual == false`.
3. `supportsHardwareDDC == true`.
4. `.brightness` capability exists with `status.isWritable == true`.

Write current `CGDirectDisplayID`. Topology signature includes ID, vendor/model/serial, brightness status and raw min/max, but excludes timestamp/current brightness to avoid write-refresh loops.

With nil serial, never synthesize identity from vendor/model/name. Such metadata is logging/snapshot-comparison only. Identical serial-less displays are both targeted. Replugged new ID gets current schedule but no old override.

### Reconciliation

Every trigger calls one private `reconcile(reason:)`:

1. Read fresh time/calendar/configuration/snapshot/eligible targets.
2. If disabled, cancel timer, clear state, publish disabled, write nothing.
3. Match active segment and next schedule boundary.
4. Remove overrides for absent displays, changed active segment, or expiry `<= now`. A one-segment override still expires at its next daily start.
5. On clock/zone changes, recalculate expiry for still-valid same-segment overrides.
6. Pick displays by reason: global triggers apply all; ordinary snapshots only new/materially changed signatures.
7. Effective value is valid manual override target, else active segment target.
8. Call `DisplayControlService.writeBrightness(displayID:normalizedValue:smooth:)` with normalized value, `smooth: false`, scheduled policy from section 5. This forces provider and emits no manual event.
9. Publish requested target/count/override count/next schedule transition, never “hardware verified”.
10. Set timer for earlier of next schedule boundary/DST transition while UI displays only schedule boundary. Early/stale callback writes nothing and recalculates.

Dispatch targets independently. One async DDC failure does not prevent other requests. Keep existing logging/restoration; v1 adds no second result-reporting interface.

### Trigger matrix

| Trigger | Overrides | Displays written | Force |
|---|---|---|---|
| Start/launch | None initially | All eligible, or wait for first eligible snapshot | Yes |
| Enable | Clear stale state | All eligible immediately | Yes |
| Enabled schedule edit | Clear all | All eligible with new active value | Yes |
| Disable | Clear/cancel | None | N/A |
| Segment boundary | Expire prior interval | All eligible | Yes |
| Clock/zone/day/DST change | Keep only still-valid same-segment overrides | All if active changes; otherwise reschedule only | Yes when written |
| Ordinary snapshot | Preserve valid | New/materially changed targets only | Yes |
| Removal | Drop its state | None for removed ID | N/A |
| Arrival/replug | Transfer none | New current ID | Yes |
| Fresh post-wake snapshot | Preserve/reapply valid manual target | All eligible effective values | Yes |

### Sleep and wake

Observe `NSWorkspace.screensDidSleepNotification`, `willSleepNotification`, `screensDidWakeNotification`, `didWakeNotification` independently:

1. Sleep marks suspended and cancels timer.
2. Duplicate wakes coalesce by generation and set `awaitingPostWakeSnapshot`.
3. Do not write in raw wake callback; service may still be suspended due callback ordering.
4. Wait for `DisplayControlService.$snapshot` timestamp newer than wake marker; service already refreshes after three seconds.
5. Force-reconcile all eligible displays, using valid override value or schedule value.
6. Reinstall timer even with no eligible display.
7. One fallback around five seconds calls public `displayControl.refresh()` if no fresh snapshot; keep waiting rather than expose/poll `isSuspended`.
8. Clear wake-pending before dispatch so write-triggered refresh cannot reenter wake handling.

### Snapshot loop prevention

Subscribe for coordinator lifetime and compare signatures, not timestamps:

- First launch snapshot: all.
- First post-wake snapshot: all.
- Added/new-ID/changed capability: affected target.
- Removed: prune.
- Same topology from `scheduleRefreshWhenIdle()`: status only, no write.

This handles wake/reconfiguration opportunistically without public suspension state or an infinite DDC loop.

## 5. Conflict policy

### Central service seam

Deepen `DisplayControlService`, rather than callbacks in every UI caller:

1. Add internal `DisplayBrightnessWritePolicy` cases `.manual` and `.scheduled`; `.manual` default.
2. Extend `writeBrightness(displayID:normalizedValue:smooth:policy:)`; existing call shape stays source-compatible.
3. Expose read-only `manualBrightnessWrites` with display ID/quantized target for accepted manual requests, emitted after guards/quantization once per intent, not smoothing frame.
4. Direct writes, `writeControl(.brightness)`, `stepValue(.brightness)`, sliders, media keys retain manual default; no UI coordinator callbacks.
5. Coordinator uses `.scheduled`, which emits no manual event and implies force.

Coordinator stores in-memory `ManualBrightnessOverride(displayID, normalizedValue, segmentID, expiresAt)`.

### Semantics

1. Slider/media-key brightness immediately wins for that display.
2. Other displays stay scheduled.
3. Override survives ordinary snapshots and wake in same segment; wake restores its recorded target.
4. Next boundary clears it, including daily start of a one-segment schedule.
5. Schedule edits, disable/re-enable, or new replug ID clear affected override.
6. Contrast/volume/mute do not interact.
7. At exact-boundary races, main-actor ordering wins: boundary clears prior interval; later manual event overrides new interval.

### Force implementation

Add `DisplayControlWriteOptions.force` to `DisplayControlProviding.writeValue`, defaulting to none. Propagate only from scheduled brightness.

`DarwinDisplayControlProvider` calls transport when forced even when `DisplayControlValueStore` has same raw value, then records success normally. Centralize via `shouldWrite(_:for:force:)` or option check beside it, with tests.

Replace `latestBrightnessTargets: [DisplayID: Double]` with a request containing target, smooth, force, policy, generation. Worker re-reads the whole latest request each loop. A forced discrete boundary arriving during manual smoothing must become final without losing force; latest intent wins.

## 6. Settings UI under `显示器`

### Placement

Create `Sources/ToolBox/DisplayControl/Schedule/BrightnessScheduleSettingsView.swift`. Insert after external/real-time controls and before status summary, outside `model.hasExternalDisplay`, so disconnected editing works.

Pass coordinator as `@ObservedObject`; reuse `SettingsView`'s existing `LaunchAtLoginController`.

Move reusable private Settings primitives (`SettingsSection`, `SettingsCard`, `SettingsInnerCard`, `SettingsValueRow`, `SettingsEmptyState`, `SettingsIconBadge`, `SettingsChrome`) unchanged to `Sources/ToolBox/Settings/SettingsChrome.swift` with internal visibility. This is mechanical and must not alter visual constants/layout.

### Interactions

All new visible/accessibility text is Chinese.

1. `定时亮度` switch commits enabled/disabled validated configuration.
2. Compact runtime row, e.g. `当前 60% · 4 台显示器 · 下次 18:00`, `1 台已手动调整，下个时段恢复`, `等待可控制的外接显示器`, `未启用`.
3. Read-only `作用范围：所有可控制的外接显示器` and `时区：系统本地（<zone>）`.
4. Stable-height rows with start editor, derived end, `0...100%` slider/stepper, trash icon with Chinese tooltip/accessibility.
5. Time-only minute-granularity `DatePicker`; discard arbitrary anchor date and persist `MinuteOfDay`.
6. Wrap shows `次日 07:00`; one segment shows `全天`.
7. `plus` icon tooltip `添加时段`; sheet/popover prefills `suggestedInsertion(after:)` and inherited brightness, committing only valid data.
8. Delete removes that start boundary, extending chronological predecessor; disable at one segment.
9. Valid edits persist immediately; no Save and no partial published state.
10. Enabled + login launch off shows nonblocking `建议开启开机自启动` and `开启` calling `setEnabled(true)`.
11. Controls remain usable disconnected; runtime shows pending.

### Validation UX

- Duplicate start: retain old schedule, show `该时间已存在，请选择其他时间` inline.
- Percent: constrain `0...100`; reject malformed decoded/manual text.
- No unused minute: disable Add, show `已无法添加更多分钟级时段`.
- Last delete: disabled.
- Save failure: retain configuration/timer, show `保存失败，当前计划未更改` and secondary localized error.
- Invalid stored document: start disabled with recoverable warning; first valid commit replaces it.

No modal validation. Verify stable dimensions/no overlap at `840x560` and minimum `760x500`.

## 7. AppDelegate wiring

Modify `Sources/ToolBox/AppDelegate.swift`:

1. Add one process-lifetime store and lazy coordinator using `DisplayControlService.shared`.
2. Launch order: `displayControl.start()`, then `brightnessSchedule.start()`. Coordinator subscribes before async refresh completes and reconciles existing snapshot.
3. Keep menu-model/media-key starts; UI lifetimes do not own schedule.
4. Inject same coordinator into `SettingsView`.
5. Termination: `brightnessSchedule.stop()` before `displayControl.stop()` to cancel timers/notifications/tasks/subscriptions first.
6. Never tie start/stop to panel/window/view appearance.

Closing Settings/panel cannot release runtime state because `AppDelegate` owns it.

## 8. File-level change list

### New application files

| File | Responsibility |
|---|---|
| `Sources/ToolBox/DisplayControl/Schedule/BrightnessSchedule.swift` | Domain, cyclic intervals/mutations, active matching, next boundary. |
| `Sources/ToolBox/DisplayControl/Schedule/BrightnessScheduleStore.swift` | Versioned defaults, atomic save, fail-closed diagnostics. |
| `Sources/ToolBox/DisplayControl/Schedule/BrightnessScheduleClock.swift` | Clock/timer seam and Foundation adapter. |
| `Sources/ToolBox/DisplayControl/Schedule/BrightnessScheduleCoordinator.swift` | Lifecycle, reconciliation, targets, overrides, wake/clock/topology, runtime state. |
| `Sources/ToolBox/DisplayControl/Schedule/BrightnessScheduleSettingsView.swift` | Chinese editor/status/validation/login recommendation. |
| `Sources/ToolBox/Settings/SettingsChrome.swift` | Existing glass primitives moved without visual changes. |

### New tests

| File | Responsibility |
|---|---|
| `Tests/ToolBoxTests/BrightnessScheduleTests.swift` | Invariants, coverage, matching, mutation, next-fire, zone, DST. |
| `Tests/ToolBoxTests/BrightnessScheduleStoreTests.swift` | Default, round-trip, corrupt, unknown, invalid persistence. |
| `Tests/ToolBoxTests/BrightnessScheduleCoordinatorTests.swift` | Fake-clock lifecycle, targeting, wake/reconfig, override, loop prevention. |

### Modified files

| File | Change |
|---|---|
| `Sources/ToolBox/DisplayControl/DisplayControlModels.swift` | Add write options; extend provider method with non-force default. |
| `Sources/ToolBox/DisplayControl/DisplayControlService.swift` | Write policy/manual stream, full pending request, force propagation. |
| `Sources/ToolBox/DisplayControl/Darwin/DarwinDisplayControlProvider.swift` | Bypass raw dedup when forced. |
| `Sources/ToolBox/DisplayControl/Darwin/DisplayControlValueStore.swift` | Force-aware eligibility if centralized here. |
| `Sources/ToolBox/SettingsView.swift` | Preserve current tabs, move chrome, inject dependencies, insert schedule outside display gating. |
| `Sources/ToolBox/AppDelegate.swift` | Own/start/stop/inject coordinator. |
| `Tests/ToolBoxTests/DisplayControlServiceTests.swift` | Record ID/options; test force, manual publication, latest full request. |
| `Tests/ToolBoxTests/DisplayControlValueStoreTests.swift` | Normal skip and forced same-raw eligibility. |
| `README.md` | Scope, override, runtime/login limitation, verification; update stale touched Settings text only. |
| `ToolBox.xcodeproj/project.pbxproj` | Regenerate via XcodeGen; never hand-edit. |

`project.yml`, `DisplayControlMenuModel.swift`, `DisplayControlMediaKeyController.swift`, `DisplayControlPanel.swift`, and `LaunchAtLoginController.swift` need no semantic change if seams are implemented as planned. Needing them should trigger a seam review.

## 9. Test plan

Write failing tests first. Use pure logic and existing `RecordingDisplayControlProvider`; never wait on real time/hardware in unit tests.

### Domain tests

1. Reject empty, duplicate ID/start, invalid minute, brightness outside range.
2. Canonicalize unsorted input without changing values/IDs.
3. One segment is 1,440 minutes and transitions at next daily start.
4. Defaults total 1,440 with `22:00-07:00` wrapping.
5. Every minute matches exactly one interval in representative schedules.
6. Exact boundary selects new; minute before selects predecessor, including before first start.
7. Add/update/delete return valid copies; collision leaves original unchanged.
8. Delete extends predecessor and cannot remove final segment.
9. Midpoint handles normal/wrap and exhaustion.
10. Midnight transition uses Calendar, not `+86,400`.
11. Identical persisted data evaluates correctly in two fixed zones.
12. `America/Los_Angeles` fixtures test missing-time adjustment, both repeated candidates, and offset-transition reconciliation.

### Persistence tests

1. Missing key gives disabled four-segment default.
2. Round-trip preserves enabled, UUIDs, starts, brightness, order.
3. Unknown schema fails closed without overwriting bytes.
4. Malformed JSON/duplicate starts fail closed.
5. Valid commit after load issue replaces and clears issue.
6. Isolated suites do not leak and are removed.

### Write-path tests

1. Normal repeated raw is skipped.
2. Forced repeated raw writes.
3. Manual brightness retains smooth/non-force default.
4. Direct, `writeControl(.brightness)`, `stepValue(.brightness)` each publish one quantized manual event; other kinds/scheduled do not.
5. Forced discrete request during in-flight smoothing becomes final and retains force.
6. Scheduled burst coalesces latest.
7. Existing contrast/brightness/volume/quantization/stale-readback tests stay green.

### Coordinator tests

1. Disabled start has no write/timer.
2. Enabled start applies current segment to every eligible external.
3. Exclude built-in, virtual, unavailable, missing/non-writable brightness.
4. Empty launch waits; later target applies.
5. Timer picks nearest boundary/DST event; boundary force-writes and schedules next.
6. Late timer/forward jump applies current once.
7. Same-segment clock/zone reschedules without write; changed segment writes all.
8. Enable/edit immediate; disable cancels.
9. Override is per display and expires while others remain scheduled.
10. Override survives ordinary snapshot/wake and wake restores value.
11. One-segment override expires next day despite same UUID.
12. Edit and disable/re-enable clear overrides.
13. Removal drops; new replug ID schedules without inheritance.
14. Two identical serial-less displays both target.
15. Same-signature post-write snapshot does not write; changed does.
16. Duplicate wakes coalesce; wait for fresh snapshot; fallback cancels.
17. One display failure does not prevent others.
18. `stop()` cancels all; later time/notifications do nothing.

### UI and integration

1. No overlap at `840x560`/`760x500`.
2. Configure disconnected, relaunch, verify persistence/waiting.
3. Two monitors both schedule; selected slider overrides one.
4. Close all UI across boundary.
5. Verify add/edit/delete, wrap/all-day, duplicate validation, Chinese text.
6. Login launch recommendation is advisory; test ServiceManagement failure.
7. Sleep/wake within/across segments gives one effective post-refresh write per display and no loop.
8. Replug serial-less with new ID applies schedule/no override transfer.
9. Change zone/clock; current segment/next fire update.
10. On write-only hardware, confirm same-value schedule reaches DDC transport.

Commands:

- `xcodegen generate`
- `xcodebuild -project ToolBox.xcodeproj -scheme ToolBox -configuration Debug -derivedDataPath build test CODE_SIGN_IDENTITY=-`
- `OPEN=0 CONFIG=Release ./build.sh`

## 10. Implementation phases

### Phase 0: Protect baseline

1. Record `git status --short`; preserve all pre-existing changes.
2. Run current tests and record pre-existing failures.
3. Re-read dirty AppDelegate/Settings/display tests before patching.

Shippable gate: no source change; baseline known.

### Phase 1: Domain and persistence

1. Add failing domain validation/coverage/wrap/boundary/mutation/zone/DST tests.
2. Implement domain until green.
3. Add failing default/round-trip/invalid/version store tests.
4. Implement versioned fail-closed store.
5. Run all tests with nothing wired.

Shippable gate: tested unused modules; app unchanged.

### Phase 2: Force-aware brightness seam

1. Extend recording provider; add failing force/manual/in-flight tests.
2. Add provider options, value-store/provider force, service policy.
3. Replace pending scalar with full request/generation.
4. Confirm old call sites/tests unchanged.

Shippable gate: no scheduler; manual behavior unchanged.

### Phase 3: Coordinator, default disabled

1. Add fake clock and tests in order: disabled, launch, boundary, filtering, override, dedup, wake, clock/replug.
2. Implement only through `start`/`stop`/`commit`.
3. Add AppDelegate lifecycle with default disabled.
4. Verify current menu/Settings unchanged without key.

Shippable gate: resident/tested, default off, no UI enable path.

### Phase 4: Chinese editor

1. Mechanically extract glass primitives; run existing layout/view tests.
2. Add schedule view with cyclic editing, errors, login recommendation.
3. Inject outside display-presence gating.
4. Test both sizes and no/one/multiple snapshots.

Shippable gate: complete configurable feature; invalid schedules cannot commit.

### Phase 5: Hardening and release

1. Repeat wake/boundary tests for leaked tasks/nondeterminism.
2. Test readable/write-only DDC, same-value force, two displays.
3. Exercise sleep/wake, panel closed, replug, login launch.
4. Update README.
5. Regenerate project, review generated diff, Debug tests, Release build.
6. `git diff --check`; do not revert/reformat unrelated dirty changes.

Shippable gate: tests, build, sizing, hardware smoke, docs pass.

## 11. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Derived ends confuse | Editor seems restrictive | Show both values; boundary edit visibly updates predecessor. |
| DST/zone/repeated time | Wrong segment | Calendar matching, first/last candidates, DST wakeup, notifications, tests; never add 86,400. |
| Timer writes before resume | Wake write drops | Cancel at sleep; wait for newer snapshot. |
| Refresh loop | DDC traffic/flicker | Signature excludes timestamp/current; clear wake state before writes; test no loop. |
| Cache skips wake value | Monitor stays reset | Force same raw through provider; test it. |
| Boundary during smoothing | Force/discrete lost | Queue full request and reread each loop. |
| Manual immediately overwritten | Hostile behavior | Per-display override through boundary, wake restore. |
| One-segment override persists | Never reasserts | Absolute next-boundary expiry and daily test. |
| Display ID changes | Stale target | Recompute snapshot, target all, persist no ID. |
| Serial-less identical panels | Unsafe pinning | No synthetic identity/pinning; both target; current-ID override only. |
| Multi-display DDC load | Slow/partial | One discrete each, serialized provider, trigger coalescing, independent dispatch. |
| Fire-and-forget status | Overstates success | Say requested/active; keep logs/restoration; hardware smoke; defer result interface. |
| Corrupt defaults | Surprise automation | Validate/fail closed/preserve bytes. |
| Invalid edit transient | Runtime gets invalid | Local draft, atomic validated commit. |
| Dirty UI extraction | Loses current polish | Re-read worktree, mechanical move, preserve constants, review separately. |
| Login registration fails | No future launch | Never block; reuse existing status/error path. |
| App exits | Schedule stops | Document and encourage login launch; daemon out of scope. |

### Potential breaking changes

1. `DisplayControlProviding.writeValue` gains options; conformers/test doubles update together; default preserves semantics.
2. Brightness queue becomes request objects; existing coalescing/smoothing tests are mandatory gates.
3. `SettingsView` initializer gains coordinator, affecting AppDelegate/previews/tests.
4. Settings helper move/access must be no-visual-change.
5. Forced schedule events add sparse DDC traffic; topology dedup/one-shot timer prevent continuous writes.
6. Enable/edit immediately changes all eligible displays; UI shows active target with no hidden delay.

## 12. Acceptance criteria

1. No preference means disabled and no scheduled write.
2. Valid minute-granularity freeform list has `0...100%`, at least one segment, exactly 1,440 minutes, no gaps/overlaps.
3. `22:00=35%`, `07:00=80%` renders `22:00-次日 07:00` and matches 35% until 07:00.
4. Exact boundary selects new value and sends once with `smooth: false`/force.
5. Enabled schedule applies current local segment on launch when snapshot exists, UI closed.
6. Every eligible external DDC display gets schedule; built-in/virtual/unavailable/non-writable gets none.
7. Post-write refresh does not duplicate; new/replugged current ID gets target.
8. Same-value schedule bypasses dedup, including write-only.
9. Slider/media-key override affects only one display until boundary; others stay scheduled.
10. Valid override force-restores after wake in same segment, clears at next boundary, never persists/transfers.
11. Sleep cancels timing; first fresh snapshot applies once per eligible display, reinstalls timer, no loop.
12. Clock/day/zone/DST changes recalculate current segment/next fire without replaying history.
13. Disable cancels/clears; re-enable applies immediately.
14. Settings > `显示器` works disconnected, is Chinese/glass-consistent, validates inline, fits `760x500`.
15. Login launch off does not block; recommendation/action appears; failures use existing path.
16. Corrupt/invalid/unknown stored data cannot enable or crash.
17. Existing display/media/menu/sleep/coalescing tests remain green.
18. New domain/store/force/coordinator/wake/override/no-loop tests pass in Debug and Release after XcodeGen.
