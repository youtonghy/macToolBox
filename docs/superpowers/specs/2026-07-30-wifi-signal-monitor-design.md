# Wi-Fi Signal Monitor Design

## Scope

ToolBox monitors only the currently associated Wi-Fi connection. It uses public
CoreWLAN APIs, performs no nearby-network scan, requests no location permission,
and does not use private KVC keys or the `airport` command.

## Architecture

- `CoreWLANWiFiProvider` owns one long-lived `CWWiFiClient` and samples its
  vended interface on a private serial queue every two seconds.
- `WiFiSnapshot` is the provider-independent connection state and converts raw
  values into display-safe signal quality, SNR, band, width, PHY, and security
  values. Zero-valued RSSI/noise/rate fields are treated as unavailable.
- `WiFiSignalModel` owns the current snapshot and five minutes of in-memory
  connected samples. Session IDs prevent callbacks from a stopped or previous
  run from updating the UI. Nothing is persisted.
- The popover and settings page observe the same model. UI code never queries
  CoreWLAN directly.

## User Interface

The popover always shows a compact Wi-Fi section after cable status and before
display control. Connected state presents quality, RSSI, SNR, link rate, and
channel. No-interface, powered-off, disconnected, and temporarily unavailable
states retain the section height and explain the condition.

Settings adds a Wi-Fi sidebar page between Cables and Displays. It includes a
five-minute RSSI/SNR chart, connection quality, radio-link details, network
identity, and the latest sample time. Missing SSID/BSSID is labelled as system
unavailable and never triggers a permission request.

## Validation

Unit tests cover quality thresholds, invalid zero measurements, SNR calculation,
channel-width labels, history trimming, and stopped/restarted session callbacks.
Layout tests cover the new fixed Wi-Fi section. The full test suite and Release
build must pass.
