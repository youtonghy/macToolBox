# Display Brightness Memory Design

## Problem

The DDC provider already attempts Get VCP reads. Some displays accept Set VCP
but do not return reliable current values. When such a display disconnects, the
transient value cache is discarded; reconnecting then exposes the 100% fallback
as though it were the current brightness.

## Design

Keep hardware reads authoritative. Add a small versioned `UserDefaults` store
for the last known brightness of displays that expose vendor, model, and serial
numbers. A successful brightness read or write updates that store. When a Get
VCP probe fails, `DisplayControlValueStore` uses the remembered percentage as
its write-only fallback; when no safe identity or remembered value exists, the
existing 100% fallback remains.

The persisted document is decoded defensively. Missing, corrupt, unknown-version,
or out-of-range entries are ignored with an OSLog error and never disable DDC
control. Displays without serial numbers are not persisted because identical
models cannot be distinguished safely across reconnects.

## Verification

- Unit-test persistence round trips and corrupt-data fallback.
- Unit-test restoration across different transient display IDs.
- Unit-test that observed hardware values override remembered values.
- Run the focused tests, full test target, Debug and Release builds, codesign
  verification, and `git diff --check`.
