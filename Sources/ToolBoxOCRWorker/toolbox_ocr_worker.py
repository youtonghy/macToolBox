#!/usr/bin/env python3
"""Local PaddleOCR worker for PP-StructureV3 and PaddleOCR-VL.

The process speaks one JSON object per line on stdin/stdout. It never resolves
models from the network; every model directory is supplied by the host app.
"""

from __future__ import annotations

import json
import os
import sys
import threading
from contextlib import redirect_stdout
from pathlib import Path
from typing import Any

from projections import structure_result, vl_result, plain


SCHEMA_VERSION = 1
MAX_PATH_BYTES = 4096
_output_lock = threading.Lock()
_active_lock = threading.Lock()
_active_task: str | None = None
_cancel_events: dict[str, threading.Event] = {}


def emit(value: dict[str, Any]) -> None:
    data = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    with _output_lock:
        sys.stdout.write(data + "\n")
        sys.stdout.flush()


def error(task_id: str, code: str, message: str) -> None:
    emit({
        "type": "error",
        "schemaVersion": SCHEMA_VERSION,
        "taskID": task_id,
        "code": code,
        "message": message[:1024],
    })


def check_path(value: str, *, relative: bool = False) -> Path:
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > MAX_PATH_BYTES:
        raise ValueError("invalid path")
    path = Path(value)
    if relative and path.is_absolute():
        raise ValueError("image path must be relative")
    if any(part in ("", ".", "..") for part in path.parts):
        raise ValueError("unsafe path")
    return path


def local_model_root(value: str) -> Path:
    root = Path(value).expanduser().resolve()
    if not root.is_dir():
        raise FileNotFoundError("model directory is missing")
    return root


def required_model_dir(root: Path, *parts: str) -> Path:
    """Resolve a catalog-relative component directory without fallback."""
    candidate = root.joinpath(*parts).resolve()
    if root not in candidate.parents or not candidate.is_dir():
        raise FileNotFoundError(f"model component is missing: {'/'.join(parts)}")
    return candidate


def construct_pipeline(pipeline: str, variant: str, root: Path) -> Any:
    # These environment flags prevent PaddleX/HuggingFace from attempting a
    # download while constructing a pipeline with a local model lease.
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    os.environ.setdefault("PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK", "True")

    if pipeline == "ppStructureV3":
        from paddleocr import PPStructureV3

        layout_dir = required_model_dir(root, "layout")
        region_dir = required_model_dir(root, "region")
        text_det_dir = required_model_dir(root, "text_det")
        text_rec_dir = required_model_dir(root, "text_rec")
        table_cls_dir = required_model_dir(root, "table_cls")
        wired_table_dir = required_model_dir(root, "table_wired")
        wireless_table_dir = required_model_dir(root, "table_wireless")
        wired_cell_dir = required_model_dir(root, "table_cell_wired")
        wireless_cell_dir = required_model_dir(root, "table_cell_wireless")
        table_orientation_dir = required_model_dir(root, "table_orientation")
        textline_orientation_dir = required_model_dir(root, "textline_orientation")
        formula_dir = required_model_dir(root, "formula")
        chart_dir = required_model_dir(root, "chart")
        return PPStructureV3(
            layout_detection_model_name="PP-DocLayout_plus-L",
            layout_detection_model_dir=str(layout_dir),
            region_detection_model_name="PP-DocBlockLayout",
            region_detection_model_dir=str(region_dir),
            text_detection_model_dir=str(text_det_dir),
            text_recognition_model_dir=str(text_rec_dir),
            table_classification_model_name="PP-LCNet_x1_0_table_cls",
            table_classification_model_dir=str(table_cls_dir),
            wired_table_structure_recognition_model_name="SLANeXt_wired",
            wired_table_structure_recognition_model_dir=str(wired_table_dir),
            wireless_table_structure_recognition_model_name="SLANet_plus",
            wireless_table_structure_recognition_model_dir=str(wireless_table_dir),
            wired_table_cells_detection_model_name="RT-DETR-L_wired_table_cell_det",
            wired_table_cells_detection_model_dir=str(wired_cell_dir),
            wireless_table_cells_detection_model_name="RT-DETR-L_wireless_table_cell_det",
            wireless_table_cells_detection_model_dir=str(wireless_cell_dir),
            table_orientation_classify_model_name="PP-LCNet_x1_0_doc_ori",
            table_orientation_classify_model_dir=str(table_orientation_dir),
            textline_orientation_model_name="PP-LCNet_x1_0_textline_ori",
            textline_orientation_model_dir=str(textline_orientation_dir),
            formula_recognition_model_name="PP-FormulaNet_plus-L",
            formula_recognition_model_dir=str(formula_dir),
            chart_recognition_model_dir=str(chart_dir),
            use_table_recognition=True,
            use_formula_recognition=True,
            use_chart_recognition=True,
            use_doc_orientation_classify=False,
            use_doc_unwarping=False,
            use_textline_orientation=False,
        )
    if pipeline == "paddleOCRVL":
        from paddleocr import PaddleOCRVL

        backend = os.environ.get("TOOLBOX_OCR_VL_BACKEND", "native")
        if backend != "native":
            raise ValueError("ToolBox only permits the local PaddleOCR-VL native backend")
        vl_dir = required_model_dir(root, "vl")
        layout_dir = required_model_dir(root, "layout")
        layout_name = "PP-DocLayoutV2" if variant == "v1" else "PP-DocLayoutV3"
        vl_name = {
            "v1": "PaddleOCR-VL-0.9B",
            "v1.5": "PaddleOCR-VL-1.5-0.9B",
            "v1.6": "PaddleOCR-VL-1.6-0.9B",
        }[variant]
        return PaddleOCRVL(
            pipeline_version=variant,
            layout_detection_model_name=layout_name,
            vl_rec_model_dir=str(vl_dir),
            vl_rec_model_name=vl_name,
            layout_detection_model_dir=str(layout_dir),
            vl_rec_backend=backend,
            use_doc_orientation_classify=False,
            use_doc_unwarping=False,
        )
    raise ValueError("unsupported pipeline")


def run_request(request: dict[str, Any], cancel_event: threading.Event) -> None:
    task_id = str(request.get("taskID", ""))
    try:
        if request.get("schemaVersion") != SCHEMA_VERSION or request.get("type", "request") != "request":
            raise ValueError("unsupported schema or message type")
        pipeline = request.get("pipeline")
        variant = request.get("variantID")
        if pipeline not in ("ppStructureV3", "paddleOCRVL"):
            raise ValueError("unsupported pipeline")
        if not isinstance(variant, str) or not variant:
            raise ValueError("invalid variant")
        image_path = check_path(request.get("imagePath", ""), relative=True)
        root = local_model_root(request.get("modelDirectory", ""))
        image_path = (Path.cwd() / image_path).resolve()
        if Path.cwd().resolve() not in image_path.parents:
            raise ValueError("image path escapes session")
        if not image_path.is_file():
            raise FileNotFoundError("input image is missing")
        from PIL import Image

        with Image.open(image_path) as image:
            width, height = image.size
        if cancel_event.is_set():
            return
        # Paddle/PaddleX writes progress and diagnostics to stdout. Keep stdout
        # exclusively for the JSONL protocol, including lazy result iteration.
        with redirect_stdout(sys.stderr):
            pipeline_instance = construct_pipeline(pipeline, variant, root)
            if cancel_event.is_set():
                return
            results = pipeline_instance.predict(str(image_path))
            if cancel_event.is_set():
                return
            if pipeline == "ppStructureV3":
                blocks = structure_result(results, width, height)
                payload = {"kind": "structured", "blocks": blocks}
            else:
                markdown, blocks = vl_result(results, width, height)
                payload = {"kind": "document", "markdown": markdown, "blocks": blocks}
        emit({
            "type": "result",
            "schemaVersion": SCHEMA_VERSION,
            "taskID": task_id,
            "pipeline": pipeline,
            "variantID": variant,
            "result": payload,
        })
    except Exception as exc:  # worker boundary: host receives a typed error
        error(task_id, "inference_failed", str(exc))


def handle(request: dict[str, Any]) -> None:
    global _active_task
    message_type = request.get("type", "request")
    if message_type == "cancel":
        task_id = str(request.get("taskID", ""))
        event = _cancel_events.get(task_id)
        if event is not None:
            event.set()
        return
    task_id = str(request.get("taskID", ""))
    with _active_lock:
        if _active_task is not None:
            error(task_id, "busy", "worker accepts one task at a time")
            return
        _active_task = task_id
        event = threading.Event()
        _cancel_events[task_id] = event
    try:
        run_request(request, event)
    finally:
        with _active_lock:
            _cancel_events.pop(task_id, None)
            _active_task = None


def main() -> int:
    threads: list[threading.Thread] = []
    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError("request must be an object")
        except Exception as exc:
            error("unknown", "invalid_json", str(exc))
            continue
        if request.get("type", "request") == "cancel":
            handle(request)
            continue
        thread = threading.Thread(target=handle, args=(request,), daemon=True)
        thread.start()
        threads.append(thread)
    for thread in threads:
        thread.join()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
