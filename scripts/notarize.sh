#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:?APP_PATH is required}"
NOTARY_APPLE_ID="${NOTARY_APPLE_ID:?NOTARY_APPLE_ID is required}"
NOTARY_PASSWORD="${NOTARY_PASSWORD:?NOTARY_PASSWORD is required}"
TEAM_ID="${TEAM_ID:?TEAM_ID is required}"

[ -d "$APP_PATH" ] || { echo "error: app not found: $APP_PATH" >&2; exit 1; }

ZIP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/toolbox-notarize.XXXXXX")"
trap 'rm -rf "$ZIP_DIR"' EXIT
ZIP="$ZIP_DIR/ToolBox.notarization.zip"

ditto -c -k --keepParent "$APP_PATH" "$ZIP"
xcrun notarytool submit "$ZIP" \
  --apple-id "$NOTARY_APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$NOTARY_PASSWORD" \
  --wait \
  --timeout 30m

xcrun stapler staple "$APP_PATH"
spctl --assess --type execute --verbose "$APP_PATH"
stapler validate "$APP_PATH"
