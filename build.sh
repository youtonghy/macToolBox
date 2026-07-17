#!/bin/bash
# Build & launch ToolBox (Route B: XcodeGen -> xcodebuild).
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${CONFIG:-Release}"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"   # ad-hoc by default; set "Developer ID Application: ..." to distribute
VERSION="${VERSION:-DEV0.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-0}"
OPEN="${OPEN:-1}"

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

APP="build/Build/Products/$CONFIG/ToolBox.app"
echo "==> built: $APP ($VERSION / $BUILD_NUMBER)"

if [ "$OPEN" = "1" ]; then
  echo "==> open"
  open "$APP"
fi
