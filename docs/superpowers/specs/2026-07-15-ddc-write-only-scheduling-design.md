# DDC Write-Only Compatibility and Write Scheduling Design

## Context

`macToolBox` can match the external display to an `IOAVService` transport, but
it currently treats a successful DDC read as a prerequisite for every control.
When a display such as the Dell U2723QE accepts Set VCP writes but does not
reliably answer Get VCP requests, the UI shows the display while disabling all
sliders.

The write path also differs from MonitorControl in two important ways:

- every interactive write performs another DDC read before writing;
- rapid input creates replace-and-cancel tasks instead of retaining one worker
  that consumes the latest target.

Cancellation cannot stop synchronous I2C work already queued in the provider.
The current cleanup paths can also clear a newer task or pending UI value. These
behaviors explain both the current read-gated controls and the previous
interleaved-write flicker.

## Goals

- Allow continuous controls to write when a hardware DDC transport exists even
  if Get VCP fails.
- Preserve values and ranges reported by displays that support reliable reads.
- Remove read-before-write traffic from the interactive write path.
- Ensure rapid slider and media-key input converges on the latest target without
  replaying stale values.
- Preserve mute-before-volume and volume-before-mute ordering.
- Prevent cancelled or completed tasks from clearing newer state.
- Cover the behavior with deterministic tests that do not require a physical
  monitor.

## Non-Goals

- Import MonitorControl's preferences, OSD, software dimming, or startup restore
  stack.
- Add per-display compatibility settings in this change.
- Change Intel or Apple Silicon packet formats, write-cycle counts, or transport
  discovery.
- Claim that an individual VCP command is readable when only writing has been
  demonstrated.

## Capability Model

Add `writeOnly` to `DisplayControlStatus`.

A control has the following states:

- `available`: Get VCP succeeded and supplied a current value and range.
- `writeOnly`: the display transport exists, but Get VCP failed. Set VCP remains
  enabled using a conservative fallback range.
- `unavailable`: no usable hardware transport exists.
- `unsupported`: the display is built-in, virtual, or otherwise outside the DDC
  hardware path.

Continuous controls and the mute button are enabled for both `available` and
`writeOnly`. The UI uses the existing backend label and adds a short write-only
indication when the selected control values are estimates. A write-only mute
value is the app's last successful request, not a claim about externally changed
monitor state.

Fallback values follow MonitorControl's conservative defaults:

| Control | Minimum | Maximum | Initial estimate |
| --- | ---: | ---: | ---: |
| Brightness | 0 | 100 | 100 |
| Contrast | 0 | 100 | 75 |
| Volume | 0 | 100 | 12 |
| Mute | 0 | 2 | unmuted (`2`) |

These are estimates, not reported hardware state. After a successful write, the
cached value becomes the last value requested successfully by this app. A later
successful read replaces the estimate with observed hardware state.

## Provider Behavior

`DarwinDisplayControlProvider` keeps a cache keyed by display and control kind.
Snapshot construction attempts Get VCP as it does today:

1. On success, normalize the reported value, cache it, and return `available`.
2. On failure with a matched transport, return `writeOnly` with the cached value
   or the fallback value.
3. Without a transport, retain the existing unavailable/unsupported behavior.

`writeValue` no longer calls `currentValueLocked` on every request. It converts
the normalized target with the cached range, or the fallback range when the
control has never been read. It then:

1. skips the transport call when the raw target equals the last successful raw
   value;
2. performs the existing Set VCP transport operation;
3. updates the cached current value and last-successful value only on success;
4. throws the existing explicit write error on failure.

The existing serial provider queue remains the single boundary around transport
state and physical DDC access.

## Service Scheduling

`DisplayControlService` owns higher-level scheduling. Its mutable scheduling
state is isolated to the main actor.

### Brightness

There is at most one brightness worker per display. A new slider or media-key
target updates `latestBrightnessTarget`; it does not cancel and replace the
worker.

The worker re-reads the latest target after every awaited write. When the start
value came from a successful DDC read or a successful app write, it advances
toward the target with the existing distance-based smoothing. When no trusted
start value exists, the first interaction writes the target directly. This
avoids sweeping the monitor from an invented fallback value.

The worker exits only when it reaches the most recent target, is suspended, or
encounters an error. Only the worker that owns the display slot may clear that
slot.

### Contrast and Mute

Each display/control pair has one latest-value worker. While one provider write
is in flight, newer input replaces the pending target. On completion the worker
writes the latest pending target, if any; intermediate targets are discarded.

### Volume

Volume uses one worker per display so mute and volume remain one ordered intent:

- zero volume writes volume zero, then mute;
- positive volume writes unmute, then volume.

New volume input replaces the pending volume intent without splitting mute and
volume across independent workers.

### Refresh and Media Keys

Writes no longer start a full snapshot refresh for every intermediate value.
After the relevant worker becomes idle, the service schedules one debounced
refresh. Cancellation of that delay returns immediately and never clears a
newer task slot.

Media-key steps use the latest scheduled value, last successful write, or
snapshot value as their baseline. They do not create independent read-modify-
write transactions for every key-repeat event.

## UI Pending State

`DisplayControlMenuModel` keeps the optimistic slider value while a write burst
is active. Replacing the pending-clear task must not let the cancelled task
continue after `Task.sleep` or clear the replacement task. The cleanup checks
cancellation and ownership before removing pending state.

Write-only controls remain visually enabled. Their displayed percentage is the
fallback estimate until the first successful write, after which it represents
the app's last successful target.

## Error Handling

- Read failure with a valid transport is a compatibility condition and results
  in `writeOnly`, not a silent error or disabled control.
- Write failure remains an error. Failed targets are not recorded as successful
  cached state.
- A worker logs the error, stops its current drain, and permits the next user
  action to start a fresh worker.
- Sleep, stop, and display reconfiguration cancel workers and discard pending
  targets. Wake-up continues to use the existing delayed snapshot refresh.
- No exception is swallowed solely to continue cleanup; cancellation exits the
  task without mutating newer ownership state.

## Testing

Add a `ToolBoxTests` XCTest target to `project.yml`. Tests use a fake provider or
transport and a controllable suspension point so ordering is deterministic.

Required regression tests:

1. A matched transport with failed reads exposes brightness, contrast, and
   volume as write-only controls with fallback values.
2. A write-only control writes using the fallback range without performing a
   new read.
3. A successful write updates cached state; a failed write does not.
4. A burst of brightness targets runs at most one smoothing worker and converges
   on the final target without stale writes after it.
5. A burst of contrast targets permits at most one in-flight write plus one
   latest pending value.
6. Volume intents preserve mute/volume ordering while coalescing newer targets.
7. Replacing a pending UI value cannot be cleared by the cancelled predecessor.
8. Repeated media-key steps accumulate from the latest scheduled value rather
   than repeatedly reading the same hardware value.

Each production behavior is implemented only after its regression test has been
run and observed failing for the expected reason.

## Documentation and Verification

Update the nearby README DDC notes to explain write-only compatibility and that
the initial displayed value may be estimated when Get VCP is unavailable.

Final verification consists of:

- focused XCTest runs for the new scheduling and provider tests;
- the full test target;
- `CONFIG=Debug OPEN=0 ./build.sh`;
- `OPEN=0 ./build.sh`;
- `git diff --check`;
- hardware smoke testing on the Dell U2723QE: sliders are enabled, each control
  responds, rapid brightness movement converges to the final value, and no old
  value is replayed after input stops.

Hardware smoke testing is the only check that can prove the monitor firmware
accepts the write-only Set VCP commands. Automated tests prove scheduling and
fallback behavior but cannot prove physical panel response.

## Success Criteria

- The detected Dell U2723QE is adjustable even when all Get VCP probes fail.
- No interactive Set VCP request performs a mandatory read first.
- Rapid input produces no stale writes after the latest target is submitted.
- The UI does not jump back because an older cancelled task cleared newer state.
- Read-capable displays retain their reported ranges and current values.
- Build, tests, formatting checks, and the Dell hardware smoke test pass.
