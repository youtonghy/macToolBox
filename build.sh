#!/bin/bash
# Build & launch ToolBox (Route B: XcodeGen -> xcodebuild).
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${CONFIG:-Release}"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"   # ad-hoc by default; set "Developer ID Application: ..." to distribute
VERSION="${VERSION:-DEV0.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-0}"
OPEN="${OPEN:-1}"

echo "==> bootstrap verified ONNX Runtime"
./scripts/bootstrap_ocr_runtime.sh

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
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  | tail -40

APP="$(pwd)/build/Build/Products/$CONFIG/ToolBox.app"
echo "==> built: $APP ($VERSION / $BUILD_NUMBER)"

if [ ! -d "$APP" ]; then
  echo "error: missing app bundle: $APP" >&2
  exit 1
fi

if [ "$OPEN" = "1" ]; then
  # Avoid Launch Services reusing a stale ToolBox from another path / old process.
  if pgrep -x ToolBox >/dev/null 2>&1; then
    echo "==> quitting existing ToolBox"
    pkill -x ToolBox || true
    # Give the old process a moment to exit cleanly.
    for _ in 1 2 3 4 5; do
      pgrep -x ToolBox >/dev/null 2>&1 || break
      sleep 0.2
    done
    pkill -9 -x ToolBox 2>/dev/null || true
  fi
  echo "==> open $APP"
  open "$APP"
  echo "==> path: $APP"
fi
