#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT="${1:-build/sbom.cdx.json}"
mkdir -p "$(dirname "$OUT")"

python3 - "$OUT" <<'PY'
import json
import re
import sys
import uuid

out = sys.argv[1]
components = [
    {
        "type": "library",
        "name": "Yams",
        "version": "5.0.6",
        "purl": "pkg:github/jpsim/Yams@5.0.6",
    },
    {
        "type": "library",
        "name": "onnxruntime",
        "version": "1.24.3",
        "purl": "pkg:generic/onnxruntime@1.24.3",
    },
    {
        "type": "library",
        "name": "CPython",
        "version": "3.11.15",
        "purl": "pkg:generic/cpython@3.11.15",
    },
]
package_pattern = re.compile(r"^([A-Za-z0-9_.-]+)==([0-9][^ ]*)")
hash_pattern = re.compile(r"--hash=sha256:([0-9a-f]{64})")

with open("third_party/ocr-worker/requirements.lock.txt", encoding="utf-8") as handle:
    lines = handle.readlines()

for index, line in enumerate(lines):
    match = package_pattern.match(line)
    if not match:
        continue
    name = match.group(1)
    version = match.group(2)
    hashes = []
    for continuation in lines[index + 1:]:
        stripped = continuation.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if not continuation[0].isspace():
            break
        digest = hash_pattern.search(continuation)
        if digest:
            hashes.append({"alg": "SHA-256", "content": digest.group(1)})
    component = {
        "type": "library",
        "name": name,
        "version": version,
        "purl": f"pkg:pypi/{name}@{version}",
    }
    if hashes:
        component["hashes"] = hashes
    components.append(component)

document = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.5",
    "serialNumber": f"urn:uuid:{uuid.uuid4()}",
    "version": 1,
    "components": components,
}
with open(out, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2)
    handle.write("\n")

print(f"SBOM written to {out}")
PY
