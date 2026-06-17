#!/bin/bash
# Build & launch ToolBox (Route B: XcodeGen -> xcodebuild).
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${CONFIG:-Release}"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"   # ad-hoc by default; set "Developer ID Application: ..." to distribute

echo "==> xcodegen generate"
xcodegen generate

echo "==> xcodebuild ($CONFIG, sign=$SIGN_IDENTITY)"
set -o pipefail
xcodebuild \
  -project ToolBox.xcodeproj \
  -scheme ToolBox \
  -configuration "$CONFIG" \
  -derivedDataPath build \
  build \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  | tail -40

APP="build/Build/Products/$CONFIG/ToolBox.app"
echo "==> built: $APP"

if [ "${OPEN:-1}" = "1" ]; then
  echo "==> open"
  open "$APP"
fi
