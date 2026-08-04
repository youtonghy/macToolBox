#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY_FILE="${OCR_CATALOG_SIGNING_KEY_FILE:-$ROOT_DIR/.build/ocr-catalog-signing.key}"
CATALOG="$ROOT_DIR/Resources/OCRModels/catalog-v1.json"
SIGNATURE="$ROOT_DIR/Resources/OCRModels/catalog-v1.sig"

[[ -f "$KEY_FILE" ]] || {
  echo "error: OCR catalog signing key is missing: $KEY_FILE" >&2
  exit 1
}

cache_dir="$ROOT_DIR/.build/swift-module-cache"
mkdir -p "$cache_dir"
SWIFT_MODULECACHE_PATH="$cache_dir" CLANG_MODULE_CACHE_PATH="$cache_dir" \
  swift "$ROOT_DIR/scripts/sign_ocr_catalog.swift" "$KEY_FILE" "$CATALOG" "$SIGNATURE"
