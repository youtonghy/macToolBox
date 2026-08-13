#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:?APP_PATH is required}"
IDENTITY="${2:?IDENTITY is required}"
ENTITLEMENTS="${3:?ENTITLEMENTS is required}"

[ -f "$ENTITLEMENTS" ] || { echo "error: entitlements file not found: $ENTITLEMENTS" >&2; exit 1; }

sign_mach_files() {
  local root="$1"
  [ -d "$root" ] || return 0
  find "$root" -type f \( -name '*.so' -o -name '*.dylib' -o -name 'python3' \) \
    -print0 | while IFS= read -r -d '' file; do
    codesign --force --timestamp --sign "$IDENTITY" "$file"
  done
}

sign_mach_files "$APP_PATH/Contents/Frameworks"

RUNTIME="$APP_PATH/Contents/Resources/ocr-worker-runtime"
if [ ! -d "$RUNTIME" ]; then
  echo "note: no OCR worker runtime to sign"
else
  sign_mach_files "$RUNTIME"
fi

# Re-signing without --entitlements drops the xcodebuild-generated xcent and can
# make hardened-runtime apps fail to load embedded third-party libraries.
codesign --force --options runtime --timestamp --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_PATH"
