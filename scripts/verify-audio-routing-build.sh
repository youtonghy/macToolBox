#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

VERIFY_ROOT="${VERIFY_ROOT:-/tmp/mactoolbox-audio-verification}"
TEST_DATA="$VERIFY_ROOT/tests"

echo "==> Bootstrap verified ONNX Runtime"
./scripts/bootstrap_ocr_runtime.sh

if [ -x ./.build/ocr-worker-runtime/bin/python3 ]; then
  ./scripts/bootstrap_ocr_worker_runtime.sh --verify-only
else
  ./scripts/bootstrap_ocr_worker_runtime.sh --bootstrap
fi

echo "==> Generate Xcode project"
xcodegen generate

echo "==> Run full unit test suite"
xcodebuild test \
  -project ToolBox.xcodeproj \
  -scheme ToolBox \
  -destination 'platform=macOS' \
  -derivedDataPath "$TEST_DATA" \
  CODE_SIGNING_ALLOWED=NO

for config in Debug Release; do
  config_data="$VERIFY_ROOT/$config"
  echo "==> Build $config"
  xcodebuild build \
    -project ToolBox.xcodeproj \
    -scheme ToolBox \
    -configuration "$config" \
    -derivedDataPath "$config_data" \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM=

  app="$config_data/Build/Products/$config/ToolBox.app"
  binary="$app/Contents/MacOS/ToolBox"
  dependency_binary="$binary"
  if [[ -f "$app/Contents/MacOS/ToolBox.debug.dylib" ]]; then
    dependency_binary="$app/Contents/MacOS/ToolBox.debug.dylib"
  fi
  test -x "$binary"
  plutil -lint "$app/Contents/Info.plist"
  codesign --verify --deep --strict "$app"
  entitlements_xml="$(codesign -d --entitlements :- "$app" 2>&1 | sed -n '/^<?xml/,$p')"
  printf '%s\n' "$entitlements_xml" | grep -Fq 'com.apple.security.cs.disable-library-validation'
  printf '%s\n' "$entitlements_xml" | grep -A1 'com.apple.security.cs.disable-library-validation' | grep -Fq '<true/>'
  dependencies="$(otool -L "$dependency_binary")"
  grep -q '/CoreAudio.framework/' <<< "$dependencies"
done

plutil -lint Resources/Info.plist Resources/ToolBox.entitlements Resources/ToolBox-AdHoc.entitlements
git diff --check

echo "==> Audio routing verification passed"
