#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/toolbox-ocr-manifest-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

runtime="$TEST_ROOT/runtime"
mkdir -p "$runtime/bin" "$runtime/include"
printf 'build\n' >"$runtime/BUILD"
printf 'bin\n' >"$runtime/bin/foo"
printf 'Python\n' >"$runtime/include/Python.h"
printf 'abstract\n' >"$runtime/include/abstract.h"

"$ROOT_DIR/scripts/prune_ocr_worker_runtime.sh" "$runtime"

manifest="$runtime/runtime.manifest.sha256"
[ -f "$manifest" ] || fail "prune did not write a content manifest"

LC_ALL=C awk '{print $2}' "$manifest" >"$TEST_ROOT/manifest-paths"
cat >"$TEST_ROOT/expected-paths" <<'EOF'
./BUILD
./bin/foo
./include/Python.h
./include/abstract.h
EOF
diff -q "$TEST_ROOT/expected-paths" "$TEST_ROOT/manifest-paths" >/dev/null \
  || fail "manifest is not in C-locale path order"

tail -r "$manifest" >"$TEST_ROOT/reversed.manifest"
mv "$TEST_ROOT/reversed.manifest" "$runtime/runtime.manifest.sha256"
if ! (
  cd "$runtime" \
    && find . -type f ! -name runtime.manifest.sha256 -print0 \
      | LC_ALL=C sort -z \
      | xargs -0 shasum -a 256 \
      | LC_ALL=C sort >"$TEST_ROOT/current" \
    && LC_ALL=C sort "$runtime/runtime.manifest.sha256" >"$TEST_ROOT/expected" \
    && diff -q "$TEST_ROOT/expected" "$TEST_ROOT/current" >/dev/null
); then
  fail "reordered manifest should still verify"
fi

echo "PASS: OCR runtime manifest is locale-stable"
