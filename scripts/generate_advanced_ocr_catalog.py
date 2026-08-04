#!/usr/bin/env python3
"""Append pinned PP-StructureV3 and PaddleOCR-VL assets to the OCR catalog."""

from __future__ import annotations

import hashlib
import json
import urllib.parse
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "Resources" / "OCRModels" / "catalog-v1.json"

REVISIONS = {
    "PaddlePaddle/PP-DocLayoutV2": "b73668227b14316a38f8b345d6b474e4f1f0b84d",
    "PaddlePaddle/PP-DocLayout_plus-L": "aa52b8528c84f9b1a34ac3a88fe0e576edb9d11d",
    "PaddlePaddle/PP-DocLayoutV3": "7b48a7566925fa464281f930c58eee04fe2c862a",
    "PaddlePaddle/PP-DocBlockLayout": "f270657da59d956ab69ffc2c4722fe1f557bf17b",
    "PaddlePaddle/PP-OCRv5_server_det": "ca867c897ecbca8873081573a802ad70d499cb94",
    "PaddlePaddle/PP-OCRv5_server_rec": "b26c3587fda8da3c8ec0ce357214b4d661ff1558",
    "PaddlePaddle/SLANeXt_wired": "763069fcda6a065f2171753205a32bf899a88d15",
    "PaddlePaddle/PP-LCNet_x1_0_table_cls": "2fa6323e7dab88fa883081db1460995f46af2922",
    "PaddlePaddle/SLANet_plus": "bae6e5f8c3c4e7da0c0b7639fdf3228fe76184e2",
    "PaddlePaddle/RT-DETR-L_wired_table_cell_det": "e2bd53c06b3a815d86acbf5c6779dada58819cfe",
    "PaddlePaddle/RT-DETR-L_wireless_table_cell_det": "25ca86356a601c877476bb0dcc5fd09153d9d64d",
    "PaddlePaddle/PP-LCNet_x1_0_doc_ori": "d3b95a6dff5fe8a94f2748e12b61cb26818a0df8",
    "PaddlePaddle/PP-LCNet_x1_0_textline_ori": "cd237a44b0e359d4fe38310a416203cf7403faa5",
    "PaddlePaddle/PP-FormulaNet_plus-L": "0809597a77f735bfb35354edb632f2e6dff606f3",
    "PaddlePaddle/PP-Chart2Table": "c3b56301c8bd63a82bcc602927e0f797d9f38096",
    "PaddlePaddle/PaddleOCR-VL": "f54aa90d389e98361cf295b7f4544bfb7452996d",
    "PaddlePaddle/PaddleOCR-VL-1.5": "426bf5b6c89670e370e71ce0c51cf2bb458b7db9",
    "PaddlePaddle/PaddleOCR-VL-1.6": "66317acc4c9fc17bd154591ce650735cd2855f3e",
}

IGNORED_FILES = {".gitattributes", "LICENSE", "README.md"}


def fetch_json(url: str) -> dict:
    with urllib.request.urlopen(url) as response:
        return json.load(response)


def sha256_for(repo: str, revision: str, filename: str, sibling: dict) -> str:
    if lfs := sibling.get("lfs"):
        if digest := lfs.get("sha256"):
            return digest
    quoted = urllib.parse.quote(filename)
    url = f"https://huggingface.co/{repo}/resolve/{revision}/{quoted}"
    digest = hashlib.sha256()
    with urllib.request.urlopen(url) as response:
        while chunk := response.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def repo_files(repo: str, destination: str, source_prefix: str = "") -> list[dict]:
    revision = REVISIONS[repo]
    metadata = fetch_json(
        f"https://huggingface.co/api/models/{repo}/revision/{revision}?blobs=true"
    )
    files = []
    for sibling in metadata["siblings"]:
        filename = sibling["rfilename"]
        if filename in IGNORED_FILES or filename.startswith("."):
            continue
        if source_prefix:
            prefix = source_prefix.rstrip("/") + "/"
            if not filename.startswith(prefix):
                continue
            relative = filename[len(prefix):]
        else:
            if filename.startswith("PP-DocLayoutV2/"):
                continue
            relative = filename
        files.append({
            "byteCount": sibling["size"],
            "relativePath": f"{destination}/{relative}",
            "sha256": sha256_for(repo, revision, filename, sibling),
            "url": f"https://huggingface.co/{repo}/resolve/{revision}/{urllib.parse.quote(filename)}",
        })
    return files


def manifest(
    model_id: str,
    pipeline: str,
    variant: str,
    display_name: str,
    files: list[dict],
) -> dict:
    return {
        "architectures": ["arm64"],
        "displayName": display_name,
        "files": files,
        "id": model_id,
        "licenseResource": "PaddleOCR-NOTICE.txt",
        "pipeline": pipeline,
        "variantID": variant,
        "version": "3.7.0-20260803-fix2",
    }


def main() -> None:
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    catalog["models"] = [
        item for item in catalog["models"]
        if item["pipeline"] == "ppOCRv6"
    ]

    structure_files = []
    for repo, destination in (
        ("PaddlePaddle/PP-DocLayout_plus-L", "layout"),
        ("PaddlePaddle/PP-DocBlockLayout", "region"),
        ("PaddlePaddle/PP-OCRv5_server_det", "text_det"),
        ("PaddlePaddle/PP-OCRv5_server_rec", "text_rec"),
        ("PaddlePaddle/PP-LCNet_x1_0_table_cls", "table_cls"),
        ("PaddlePaddle/SLANeXt_wired", "table_wired"),
        ("PaddlePaddle/SLANet_plus", "table_wireless"),
        ("PaddlePaddle/RT-DETR-L_wired_table_cell_det", "table_cell_wired"),
        ("PaddlePaddle/RT-DETR-L_wireless_table_cell_det", "table_cell_wireless"),
        ("PaddlePaddle/PP-LCNet_x1_0_doc_ori", "table_orientation"),
        ("PaddlePaddle/PP-LCNet_x1_0_textline_ori", "textline_orientation"),
        ("PaddlePaddle/PP-FormulaNet_plus-L", "formula"),
        ("PaddlePaddle/PP-Chart2Table", "chart"),
    ):
        structure_files.extend(repo_files(repo, destination))
    catalog["models"].append(manifest(
        "ppstructurev3-default",
        "ppStructureV3",
        "default",
        "PP-StructureV3 Full",
        structure_files,
    ))

    vl_repos = {
        "v1": "PaddlePaddle/PaddleOCR-VL",
        "v1.5": "PaddlePaddle/PaddleOCR-VL-1.5",
        "v1.6": "PaddlePaddle/PaddleOCR-VL-1.6",
    }
    for variant, repo in vl_repos.items():
        files = repo_files(repo, "vl")
        if variant == "v1":
            files.extend(repo_files(repo, "layout", "PP-DocLayoutV2"))
        else:
            files.extend(repo_files("PaddlePaddle/PP-DocLayoutV3", "layout"))
        catalog["models"].append(manifest(
            f"paddleocr-vl-{variant}",
            "paddleOCRVL",
            variant,
            f"PaddleOCR-VL {variant}",
            files,
        ))

    CATALOG.write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
