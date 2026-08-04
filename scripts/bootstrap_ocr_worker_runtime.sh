#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="$ROOT_DIR/third_party/ocr-worker/dependencies.lock.json"
REQUIREMENTS_LOCK="$ROOT_DIR/third_party/ocr-worker/requirements.lock.txt"
WORKER_SOURCE="$ROOT_DIR/Sources/ToolBoxOCRWorker"
RUNTIME_DIR="$ROOT_DIR/.build/ocr-worker-runtime"
PYTHON_VERSION="${TOOLBOX_OCR_PYTHON_VERSION:-3.11.15}"

usage() {
  echo "usage: $0 [--verify-only] [--bootstrap]" >&2
}

mode="--verify-only"
if [[ $# -gt 0 ]]; then
  mode="$1"
fi
if [[ "$mode" != "--verify-only" && "$mode" != "--bootstrap" ]]; then
  usage
  exit 2
fi

command -v python3 >/dev/null || {
  echo "error: python3 is required" >&2
  exit 1
}
[[ -f "$LOCK_FILE" ]] || { echo "error: missing dependency lock" >&2; exit 1; }
[[ -f "$REQUIREMENTS_LOCK" ]] || { echo "error: missing hashed requirements lock" >&2; exit 1; }
[[ -f "$WORKER_SOURCE/toolbox_ocr_worker.py" ]] || {
  echo "error: missing worker entrypoint" >&2
  exit 1
}
[[ -f "$WORKER_SOURCE/projections.py" ]] || {
  echo "error: missing worker projections" >&2
  exit 1
}

python3 - "$LOCK_FILE" <<'PY'
import json
import sys
from pathlib import Path

lock = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert lock.get("schemaVersion") == 1
assert isinstance(lock.get("python"), dict)
assert lock["python"].get("version")
packages = lock.get("packages")
assert isinstance(packages, list) and packages
for package in packages:
    assert package.get("name") and package.get("version")
    assert package.get("requirementsFile") == "requirements.lock.txt"
PY

grep -q -- '--hash=sha256:' "$REQUIREMENTS_LOCK" || {
  echo "error: OCR worker requirements are not hash locked" >&2
  exit 1
}

python3 -m py_compile "$WORKER_SOURCE/toolbox_ocr_worker.py" "$WORKER_SOURCE/projections.py"
mkdir -p "$RUNTIME_DIR/bin"

if [[ "$mode" == "--verify-only" ]]; then
  if [[ -x "$RUNTIME_DIR/bin/python3" ]]; then
    PADDLE_PDX_CACHE_HOME="$RUNTIME_DIR/.verify-cache" \
      HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
      "$RUNTIME_DIR/bin/python3" - <<'PY'
import paddle
import paddleocr
from PIL import Image
from paddleocr import PPStructureV3, PaddleOCRVL
PY
    rm -rf "$RUNTIME_DIR/.verify-cache"
    echo "OCR worker runtime and Python sources verified"
  else
    echo "OCR worker source and dependency manifest verified (runtime not bootstrapped)"
  fi
  exit 0
fi

command -v uv >/dev/null || {
  echo "error: uv is required for --bootstrap (install from https://docs.astral.sh/uv/)" >&2
  exit 1
}

staging_dir="$RUNTIME_DIR.staging.$$"
rm -rf "$staging_dir"
mkdir -p "$staging_dir"
uv python install "$PYTHON_VERSION" --install-dir "$staging_dir/python" --no-bin
python_root="$(find "$staging_dir/python" -maxdepth 1 -type d -name 'cpython-*' -print -quit)"
[[ -n "$python_root" ]] || { echo "error: uv did not install CPython $PYTHON_VERSION" >&2; exit 1; }
mkdir -p "$staging_dir/runtime"
cp -R "$python_root/." "$staging_dir/runtime/"
mkdir -p "$staging_dir/runtime/lib/python3.11/site-packages"

uv pip install \
  --target "$staging_dir/runtime/lib/python3.11/site-packages" \
  --python-version 3.11 \
  --require-hashes \
  --requirement "$REQUIREMENTS_LOCK"

mkdir -p "$staging_dir/runtime/bin"
cp -L "$staging_dir/runtime/bin/python3.11" "$staging_dir/runtime/bin/python3.regular"
mv -f "$staging_dir/runtime/bin/python3.regular" "$staging_dir/runtime/bin/python3"
chmod 755 "$staging_dir/runtime/bin/python3"
PADDLE_PDX_CACHE_HOME="$staging_dir/runtime/.verify-cache" \
  HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
  "$staging_dir/runtime/bin/python3" - <<'PY'
import paddle
import paddleocr
from PIL import Image
from paddleocr import PPStructureV3, PaddleOCRVL
PY
rm -rf "$staging_dir/runtime/.verify-cache"
rm -rf "$RUNTIME_DIR"
mv "$staging_dir/runtime" "$RUNTIME_DIR"
rm -rf "$staging_dir"
echo "OCR worker runtime bootstrapped at $RUNTIME_DIR"
