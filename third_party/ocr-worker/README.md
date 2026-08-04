# ToolBox OCR Worker

The application launches `toolbox_ocr_worker.py` as a local JSONL process for
PP-StructureV3 and PaddleOCR-VL. The worker receives a private PNG path and a
verified model lease; it must not download weights or call a remote inference
service.

The lock files record CPython 3.11.15 and the macOS arm64 wheel hashes resolved
for PaddleOCR 3.7.0 / PaddlePaddle 3.2.1. `bootstrap_ocr_worker_runtime.sh
--bootstrap` creates a relocatable standalone interpreter, installs the hashed
wheel set, verifies imports, and places the result in
`.build/ocr-worker-runtime`. Release packaging embeds that directory alongside
the JSONL worker. Model weights are separate, user-consented downloads and are
verified by the signed OCR catalog before a lease can be acquired.

`scripts/generate_advanced_ocr_catalog.py` rebuilds advanced entries only from
the pinned Hugging Face revisions in that script. After reviewing the diff, run
`scripts/sign_ocr_catalog.sh`; it reads the ignored local key from
`.build/ocr-catalog-signing.key` or `OCR_CATALOG_SIGNING_KEY_FILE` and prints the
public key that must match `OCRModelCatalogLoader.shipped`.
