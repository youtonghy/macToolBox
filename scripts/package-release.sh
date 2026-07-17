#!/bin/bash
# Package ToolBox.app + DMG for a given version.
# Usage: VERSION=1.2.3 APP_PATH=build/Build/Products/Release/ToolBox.app ./scripts/package-release.sh
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${VERSION:?VERSION is required}"
APP_PATH="${APP_PATH:-build/Build/Products/Release/ToolBox.app}"
OUT_DIR="${OUT_DIR:-dist}"

if [ ! -d "$APP_PATH" ]; then
  echo "error: app not found at $APP_PATH" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
STAGE="$OUT_DIR/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"

cp -R "$APP_PATH" "$STAGE/ToolBox.app"

APP_ZIP="$OUT_DIR/ToolBox-${VERSION}.app.zip"
DMG="$OUT_DIR/ToolBox-${VERSION}.dmg"

rm -f "$APP_ZIP" "$DMG"

echo "==> zip app -> $APP_ZIP"
ditto -c -k --keepParent "$STAGE/ToolBox.app" "$APP_ZIP"

echo "==> dmg -> $DMG"
hdiutil create \
  -volname "ToolBox ${VERSION}" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG"

rm -rf "$STAGE"

echo "==> packaged:"
ls -lh "$APP_ZIP" "$DMG"
