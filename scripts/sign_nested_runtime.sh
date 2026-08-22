#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:?APP_PATH is required}"
IDENTITY="${2:?IDENTITY is required}"
ENTITLEMENTS="${3:?ENTITLEMENTS is required}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI_ENTITLEMENTS="$SCRIPT_DIR/../Resources/ToolBoxCLI.entitlements"

[ -f "$ENTITLEMENTS" ] || { echo "error: entitlements file not found: $ENTITLEMENTS" >&2; exit 1; }
[ -f "$CLI_ENTITLEMENTS" ] || { echo "error: CLI entitlements file not found: $CLI_ENTITLEMENTS" >&2; exit 1; }

codesign_path() {
  local path="$1"
  shift
  if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign "$IDENTITY" "$@" "$path"
  else
    codesign --force --timestamp --sign "$IDENTITY" "$@" "$path"
  fi
}

sign_mach_files() {
  local root="$1"
  [ -d "$root" ] || return 0
  find "$root" -type f \( -name '*.so' -o -name '*.dylib' -o -name 'python3' \) \
    -print0 | while IFS= read -r -d '' file; do
    codesign_path "$file"
  done
}

sign_mach_files "$APP_PATH/Contents/Frameworks"

CLI_HELPER="$APP_PATH/Contents/Helpers/toolbox"
if [ ! -x "$CLI_HELPER" ]; then
  echo "error: bundled CLI helper is missing or not executable: $CLI_HELPER" >&2
  exit 1
fi
codesign_path "$CLI_HELPER" --options runtime --entitlements "$CLI_ENTITLEMENTS"

RUNTIME="$APP_PATH/Contents/Resources/ocr-worker-runtime"
if [ ! -d "$RUNTIME" ]; then
  echo "note: no OCR worker runtime to sign"
else
  sign_mach_files "$RUNTIME"
fi

# Re-signing without --entitlements drops the xcodebuild-generated xcent and can
# make hardened-runtime apps fail to load embedded third-party libraries.
codesign_path "$APP_PATH" --options runtime --entitlements "$ENTITLEMENTS"
