#!/usr/bin/env bash
set -euo pipefail

RUNTIME_ROOT="${1:?runtime root is required}"

if [ ! -d "$RUNTIME_ROOT" ]; then
  echo "error: runtime root missing: $RUNTIME_ROOT" >&2
  exit 1
fi

# Remove test suites, bytecode, Windows launchers, static archives, and TLS
# fixtures that are not needed by the OCR worker. certifi's CA bundle is kept.
find "$RUNTIME_ROOT" -type d \( -name tests -o -name test \) -prune -exec rm -rf {} +
find "$RUNTIME_ROOT" -type d \( -name __pycache__ -o -name idlelib -o -name turtledemo -o -name ensurepip \) -prune -exec rm -rf {} +
find "$RUNTIME_ROOT" -type f \( -name '*.pyc' -o -name '*.exe' -o -name '*.a' \) -delete
find "$RUNTIME_ROOT" -type f -name '*.pem' ! -path '*/certifi/*' -delete

if find "$RUNTIME_ROOT" -type f -name '*.exe' -print -quit | grep -q .; then
  echo "error: Windows executables remain in OCR runtime" >&2
  exit 1
fi
if find "$RUNTIME_ROOT" -type d -name tests -print -quit | grep -q .; then
  echo "error: test directories remain in OCR runtime" >&2
  exit 1
fi

# Record a content digest so later builds can reject a stale or modified cache.
# C locale keeps the file order stable across machines and macOS collations.
cd "$RUNTIME_ROOT"
find . -type f ! -name runtime.manifest.sha256 -print0 \
  | LC_ALL=C sort -z \
  | xargs -0 shasum -a 256 \
  > runtime.manifest.sha256
