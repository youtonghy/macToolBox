#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:?APP_PATH is required}"
IDENTITY="${2:?IDENTITY is required}"

RUNTIME="$APP_PATH/Contents/Resources/ocr-worker-runtime"
if [ ! -d "$RUNTIME" ]; then
  echo "note: no OCR worker runtime to sign"
  exit 0
fi

find "$RUNTIME" -type f \
  \( -name '*.so' -o -name '*.dylib' -o -name 'python3' \) \
  -print0 | while IFS= read -r -d '' file; do
  codesign --force --timestamp --sign "$IDENTITY" "$file"
done

codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP_PATH"
