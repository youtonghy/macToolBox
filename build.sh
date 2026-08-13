#!/bin/bash
# Build & launch ToolBox (Route B: XcodeGen -> xcodebuild).
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${CONFIG:-Release}"
VERSION="${VERSION:-DEV0.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-0}"
OPEN="${OPEN:-1}"
BUNDLE_ID="com.youtonghy.toolbox"
INSTALL_APP_PATH="${INSTALL_APP_PATH:-/Applications/ToolBox.app}"
SIGN_IDENTITY_FILE="${SIGN_IDENTITY_FILE:-$HOME/Library/Application Support/ToolBox/build-signing-identity}"
ALLOW_ADHOC="${ALLOW_ADHOC:-0}"
ENTITLEMENTS="Resources/ToolBox-AdHoc.entitlements"

IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
REQUESTED_IDENTITY="${CODE_SIGN_IDENTITY:-}"
SIGN_IDENTITY=""

identity_hash_for() {
  local requested="$1"

  if [[ "$requested" =~ ^[[:xdigit:]]{40}$ ]]; then
    printf '%s\n' "$IDENTITIES" | awk -v hash="$requested" '$2 == hash { print $2; exit }'
  else
    printf '%s\n' "$IDENTITIES" \
      | sed -n 's/^[[:space:]]*[0-9]*) \([[:xdigit:]]\{40\}\) "\(.*\)"$/\1|\2/p' \
      | awk -F '|' -v name="$requested" '$2 == name { print $1; exit }'
  fi
}

identity_name_for_hash() {
  local hash="$1"

  printf '%s\n' "$IDENTITIES" \
    | sed -n 's/^[[:space:]]*[0-9]*) \([[:xdigit:]]\{40\}\) "\(.*\)"$/\1|\2/p' \
    | awk -F '|' -v requested_hash="$hash" '$1 == requested_hash { print substr($0, index($0, "|") + 1); exit }'
}

if [ -f "$SIGN_IDENTITY_FILE" ]; then
  SIGN_IDENTITY="$(tr -d '[:space:]' <"$SIGN_IDENTITY_FILE")"
  if ! [[ "$SIGN_IDENTITY" =~ ^[[:xdigit:]]{40}$ ]]; then
    echo "error: invalid signing identity file: $SIGN_IDENTITY_FILE" >&2
    exit 1
  fi
  if [ -z "$(identity_hash_for "$SIGN_IDENTITY")" ]; then
    echo "error: locked signing identity is no longer valid: $SIGN_IDENTITY" >&2
    echo "error: restore that certificate or remove $SIGN_IDENTITY_FILE to select a new identity" >&2
    exit 1
  fi

  if [ -n "$REQUESTED_IDENTITY" ] && [ "$REQUESTED_IDENTITY" != "-" ]; then
    REQUESTED_HASH="$(identity_hash_for "$REQUESTED_IDENTITY")"
    if [ -z "$REQUESTED_HASH" ]; then
      echo "error: requested signing identity is not valid: $REQUESTED_IDENTITY" >&2
      exit 1
    fi
    if [ "$REQUESTED_HASH" != "$SIGN_IDENTITY" ]; then
      echo "error: requested identity differs from locked identity $SIGN_IDENTITY" >&2
      echo "error: remove $SIGN_IDENTITY_FILE only when intentionally rotating certificates" >&2
      exit 1
    fi
  fi
elif [ -n "$REQUESTED_IDENTITY" ] && [ "$REQUESTED_IDENTITY" != "-" ]; then
  SIGN_IDENTITY="$(identity_hash_for "$REQUESTED_IDENTITY")"
  if [ -z "$SIGN_IDENTITY" ]; then
    echo "error: requested signing identity is not valid: $REQUESTED_IDENTITY" >&2
    exit 1
  fi
elif [ "$REQUESTED_IDENTITY" != "-" ]; then
  SIGN_IDENTITY="$(printf '%s\n' "$IDENTITIES" \
    | sed -n 's/^[[:space:]]*[0-9]*) \([[:xdigit:]]\{40\}\) "Developer ID Application:.*$/\1/p' \
    | head -1)"
  if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(printf '%s\n' "$IDENTITIES" \
      | sed -n 's/^[[:space:]]*[0-9]*) \([[:xdigit:]]\{40\}\) "Apple Development:.*$/\1/p' \
      | head -1)"
  fi
  if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(printf '%s\n' "$IDENTITIES" \
      | sed -n 's/^[[:space:]]*[0-9]*) \([[:xdigit:]]\{40\}\) "youtonghy"$/\1/p' \
      | head -1)"
  fi
fi

if [ -n "$SIGN_IDENTITY" ]; then
  mkdir -p "$(dirname "$SIGN_IDENTITY_FILE")"
  printf '%s\n' "$SIGN_IDENTITY" >"$SIGN_IDENTITY_FILE"
  SIGN_IDENTITY_NAME="$(identity_name_for_hash "$SIGN_IDENTITY")"
  case "$SIGN_IDENTITY_NAME" in
    "Apple Development:"*|"Apple Distribution:"*|"Developer ID Application:"*|"Mac Developer:"*|"3rd Party Mac Developer Application:"*)
      ENTITLEMENTS="Resources/ToolBox.entitlements"
      ;;
    *)
      echo "warning: local signing identity has no Apple Team ID; disabling library validation for embedded ONNX Runtime" >&2
      ;;
  esac
  echo "==> locked signing identity: $SIGN_IDENTITY ($SIGN_IDENTITY_NAME)"
elif [ "$ALLOW_ADHOC" = "1" ]; then
  SIGN_IDENTITY="-"
  echo "warning: ALLOW_ADHOC=1; TCC grants may not survive this rebuild" >&2
else
  echo "error: no valid Apple Development signing identity found" >&2
  echo "error: install a stable signing certificate, or use ALLOW_ADHOC=1 for a one-off build" >&2
  echo "error: ad-hoc builds cannot reliably preserve macOS privacy permissions" >&2
  exit 1
fi

echo "==> bootstrap verified ONNX Runtime"
./scripts/bootstrap_ocr_runtime.sh

echo "==> bootstrap verified OCR worker source/runtime"
if [ -x ./scripts/bootstrap_ocr_worker_runtime.sh ]; then
  if [ -x ./.build/ocr-worker-runtime/bin/python3 ]; then
    ./scripts/bootstrap_ocr_worker_runtime.sh --verify-only
  else
    ./scripts/bootstrap_ocr_worker_runtime.sh --bootstrap
  fi
else
  echo "warning: OCR worker bootstrap script is missing; advanced OCR will be unavailable" >&2
fi

# pytest and local Python runs may create bytecode in the bundled source folder.
find "$(pwd)/Sources/ToolBoxOCRWorker" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true

echo "==> xcodegen generate"
xcodegen generate

echo "==> xcodebuild ($CONFIG, version=$VERSION ($BUILD_NUMBER), sign=$SIGN_IDENTITY)"
set -o pipefail
xcodebuild \
  -project ToolBox.xcodeproj \
  -scheme ToolBox \
  -configuration "$CONFIG" \
  -derivedDataPath build \
  build \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS" \
  DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  | tail -40

APP="$(pwd)/build/Build/Products/$CONFIG/ToolBox.app"
echo "==> built: $APP ($VERSION / $BUILD_NUMBER)"

if [ ! -d "$APP" ]; then
  echo "error: missing app bundle: $APP" >&2
  exit 1
fi

if [ "$SIGN_IDENTITY" != "-" ] && [ -x ./scripts/sign_nested_runtime.sh ]; then
  ./scripts/sign_nested_runtime.sh "$APP" "$SIGN_IDENTITY" "$ENTITLEMENTS"
fi

BUILT_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [ "$BUILT_BUNDLE_ID" != "$BUNDLE_ID" ]; then
  echo "error: unexpected bundle identifier '$BUILT_BUNDLE_ID' in $APP" >&2
  exit 1
fi

codesign --verify --deep --strict "$APP"

if [ "${SKIP_INSTALL:-0}" = "1" ]; then
  echo "==> SKIP_INSTALL=1; leaving app at $APP"
  exit 0
fi

# Stop the running app only after a valid replacement is ready to install.
if pgrep -x ToolBox >/dev/null 2>&1; then
  echo "==> quitting existing ToolBox process"
  pkill -x ToolBox || true
  for _ in 1 2 3 4 5; do
    pgrep -x ToolBox >/dev/null 2>&1 || break
    sleep 0.2
  done
  pkill -9 -x ToolBox 2>/dev/null || true
fi

if [ -L "$INSTALL_APP_PATH" ]; then
  echo "error: refusing to replace symlink destination: $INSTALL_APP_PATH" >&2
  exit 1
fi

mkdir -p "$(dirname "$INSTALL_APP_PATH")"
STAGED_APP="$INSTALL_APP_PATH.new.$$"
OLD_APP="$INSTALL_APP_PATH.old.$$"
rm -rf "$STAGED_APP" "$OLD_APP"
cp -R "$APP" "$STAGED_APP"

INSTALLED_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGED_APP/Contents/Info.plist" 2>/dev/null || true)"
if [ "$INSTALLED_BUNDLE_ID" != "$BUNDLE_ID" ]; then
  echo "error: staged bundle identifier verification failed: $STAGED_APP" >&2
  rm -rf "$STAGED_APP"
  exit 1
fi
codesign --verify --deep --strict "$STAGED_APP"

if [ -d "$INSTALL_APP_PATH" ]; then
  mv "$INSTALL_APP_PATH" "$OLD_APP"
fi
if ! mv "$STAGED_APP" "$INSTALL_APP_PATH"; then
  if [ -d "$OLD_APP" ]; then
    mv "$OLD_APP" "$INSTALL_APP_PATH"
  fi
  echo "error: failed to install staged app at $INSTALL_APP_PATH" >&2
  exit 1
fi

INSTALLED_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALL_APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
if [ "$INSTALLED_BUNDLE_ID" != "$BUNDLE_ID" ]; then
  if [ -d "$OLD_APP" ]; then
    rm -rf "$INSTALL_APP_PATH"
    mv "$OLD_APP" "$INSTALL_APP_PATH"
  fi
  echo "error: installed bundle identifier verification failed: $INSTALL_APP_PATH" >&2
  exit 1
fi
codesign --verify --deep --strict "$INSTALL_APP_PATH" || {
  if [ -d "$OLD_APP" ]; then
    rm -rf "$INSTALL_APP_PATH"
    mv "$OLD_APP" "$INSTALL_APP_PATH"
  fi
  echo "error: installed bundle verification failed: $INSTALL_APP_PATH" >&2
  exit 1
}
rm -rf "$OLD_APP"

echo "==> installed in place: $INSTALL_APP_PATH"
if [ "$SIGN_IDENTITY" != "-" ]; then
  echo "==> designated requirement:"
  codesign -d -r- "$INSTALL_APP_PATH" 2>&1 | sed -n 's/^designated => /    /p'
fi

if [ "$OPEN" = "1" ]; then
  echo "==> open $INSTALL_APP_PATH"
  open "$INSTALL_APP_PATH"
fi
