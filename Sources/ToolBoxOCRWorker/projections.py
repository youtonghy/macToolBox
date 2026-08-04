"""Normalize PaddleOCR pipeline objects into the ToolBox JSONL contract."""

from __future__ import annotations

import json
import math
import re
from collections.abc import Mapping, Sequence
from typing import Any


MAX_TEXT_BYTES = 16 * 1024 * 1024


def plain(value: Any) -> Any:
    """Convert PaddleX result wrappers into JSON-compatible Python values."""
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, Mapping):
        return {str(key): plain(item) for key, item in value.items()}
    if isinstance(value, Sequence) and not isinstance(value, (bytes, bytearray, str)):
        return [plain(item) for item in value]
    for attr in ("json", "to_dict", "dict"):
        candidate = getattr(value, attr, None)
        if candidate is None:
            continue
        try:
            converted = candidate() if callable(candidate) else candidate
        except Exception:
            continue
        if isinstance(converted, str):
            try:
                converted = json.loads(converted)
            except json.JSONDecodeError:
                pass
        return plain(converted)
    return {}


def _number(value: Any, default: float = 0.0) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    return number if math.isfinite(number) else default


def _point(value: Any, width: float, height: float) -> list[float]:
    if isinstance(value, Mapping):
        x = _number(value.get("x", value.get("left", 0)))
        y = _number(value.get("y", value.get("top", 0)))
    elif isinstance(value, Sequence) and len(value) >= 2:
        x = _number(value[0])
        y = _number(value[1])
    else:
        x = y = 0.0
    if width > 0:
        x /= width
    if height > 0:
        y /= height
    return [max(0.0, min(1.0, x)), max(0.0, min(1.0, y))]


def polygon(value: Any, width: int, height: int) -> list[list[float]]:
    """Return a normalized quadrilateral for points or an xyxy box."""
    if isinstance(value, Mapping):
        value = value.get("points", value.get("polygon", value.get("bbox", [])))
    if isinstance(value, Sequence) and len(value) == 1 and isinstance(value[0], Sequence):
        value = value[0]
    if isinstance(value, Sequence) and len(value) == 4 and all(
        isinstance(point, Sequence) and len(point) >= 2 for point in value
    ):
        points = [_point(point, width, height) for point in value]
        return points
    if isinstance(value, Sequence) and len(value) >= 4 and all(
        isinstance(item, (int, float)) for item in value[:4]
    ):
        left, top, right, bottom = (_number(item) for item in value[:4])
        return [
            _point([left, top], width, height),
            _point([right, top], width, height),
            _point([right, bottom], width, height),
            _point([left, bottom], width, height),
        ]
    return [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]]


def _text(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).replace("\x00", "").strip()
    if not text:
        return None
    encoded = text.encode("utf-8")
    if len(encoded) > MAX_TEXT_BYTES:
        raise ValueError("text exceeds maximum size")
    return text


def _list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def _layout_entries(page: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    candidates = (
        page.get("layout_det_res"),
        page.get("layout_res"),
        page.get("layout"),
    )
    for candidate in candidates:
        candidate = plain(candidate)
        if isinstance(candidate, Mapping):
            boxes = candidate.get("boxes", candidate.get("layout", []))
            if isinstance(boxes, list):
                return [item for item in boxes if isinstance(item, Mapping)]
        if isinstance(candidate, list):
            return [item for item in candidate if isinstance(item, Mapping)]
    return []


def structure_blocks(page_value: Any, width: int, height: int) -> list[dict[str, Any]]:
    page = plain(page_value)
    if not isinstance(page, Mapping):
        return []
    blocks: list[dict[str, Any]] = []
    for index, entry in enumerate(_layout_entries(page)):
        label = _text(entry.get("label", entry.get("type", "other"))) or "other"
        text = _text(entry.get("text", entry.get("content")))
        html_value = sanitize_html(entry.get("html", entry.get("pred_html")))
        score = entry.get("score", entry.get("confidence"))
        confidence = _number(score) if score is not None else None
        blocks.append({
            "id": str(entry.get("id", f"layout-{index}")),
            "kind": label,
            "polygon": polygon(entry.get("bbox", entry.get("polygon")), width, height),
            "text": text,
            "html": html_value,
            "confidence": confidence,
        })

    overall = plain(page.get("overall_ocr_res", {}))
    if isinstance(overall, Mapping):
        texts = _list(overall.get("rec_texts"))
        polys = _list(overall.get("rec_polys", overall.get("dt_polys")))
        scores = _list(overall.get("rec_scores"))
        for index, text_value in enumerate(texts):
            text = _text(text_value)
            if text is None:
                continue
            blocks.append({
                "id": f"ocr-{index}",
                "kind": "paragraph",
                "polygon": polygon(polys[index] if index < len(polys) else None, width, height),
                "text": text,
                "html": None,
                "confidence": _number(scores[index]) if index < len(scores) else None,
            })

    for index, table in enumerate(_list(page.get("table_res_list"))):
        table = plain(table)
        if not isinstance(table, Mapping):
            continue
        html_value = sanitize_html(table.get("pred_html"))
        cells = _list(table.get("cell_box_list"))
        box = cells[0] if cells else table.get("bbox", table.get("polygon"))
        blocks.append({
            "id": f"table-{index}",
            "kind": "table",
            "polygon": polygon(box, width, height),
            "text": None,
            "html": html_value,
            "confidence": None,
        })

    for kind, key, text_keys in (
        ("formula", "formula_res_list", ("rec_formula", "formula")),
        ("chart", "chart_res_list", ("markdown", "text", "result")),
    ):
        for index, item in enumerate(_list(page.get(key))):
            item = plain(item)
            if not isinstance(item, Mapping):
                continue
            text = None
            for candidate in text_keys:
                text = _text(item.get(candidate))
                if text is not None:
                    break
            box = item.get("dt_polys", item.get("bbox", item.get("polygon")))
            blocks.append({
                "id": f"{kind}-{index}",
                "kind": kind,
                "polygon": polygon(box, width, height),
                "text": text,
                "html": sanitize_html(item.get("html")),
                "confidence": _number(item.get("score")) if item.get("score") is not None else None,
            })
    return blocks


def sanitize_markdown(value: Any) -> str:
    markdown = _text(value) or ""
    markdown = re.sub(r"(?i)javascript:", "", markdown)
    markdown = re.sub(r"(?i)data:[^ )]+", "", markdown)
    markdown = re.sub(r"<script\b[^>]*>.*?</script>", "", markdown, flags=re.I | re.S)
    return markdown


def sanitize_html(value: Any) -> str | None:
    text = _text(value)
    if text is None:
        return None
    text = re.sub(r"(?is)<script\b[^>]*>.*?</script>", "", text)
    text = re.sub(r"(?i)\s+on[a-z]+\s*=\s*(['\"]).*?\1", "", text)
    text = re.sub(r"(?i)javascript:", "", text)
    return text


def _utf16_length(value: str) -> int:
    return len(value.encode("utf-16-le")) // 2


def document_blocks(
    result_value: Any,
    markdown: str,
    width: int,
    height: int,
    search_from: int = 0,
) -> list[dict[str, Any]]:
    value = plain(result_value)
    if not isinstance(value, Mapping):
        return []
    candidates = value.get("parsing_res_list", value.get("layout_det_res", value.get("layout", [])))
    candidates = plain(candidates)
    if not isinstance(candidates, list):
        return []
    blocks: list[dict[str, Any]] = []
    cursor = search_from
    for index, entry in enumerate(candidates):
        if not isinstance(entry, Mapping):
            continue
        text = _text(entry.get("text", entry.get("content")))
        start = end = None
        if text:
            cursor = markdown.find(text, cursor)
            if cursor >= 0:
                start = _utf16_length(markdown[:cursor])
                end = start + _utf16_length(text)
                cursor += len(text)
        blocks.append({
            "id": str(entry.get("id", f"block-{index}")),
            "kind": _text(entry.get("label", entry.get("type", "other"))) or "other",
            "polygon": polygon(entry.get("bbox", entry.get("polygon")), width, height),
            "text": None,
            "html": None,
            "confidence": _number(entry.get("score")) if entry.get("score") is not None else None,
            "markdownStart": start,
            "markdownEnd": end,
        })
    return blocks


def structure_result(results: Any, width: int, height: int) -> list[dict[str, Any]]:
    pages = results if isinstance(results, list) else [results]
    blocks: list[dict[str, Any]] = []
    for page in pages:
        blocks.extend(structure_blocks(page, width, height))
    return blocks


def vl_result(results: Any, width: int, height: int) -> tuple[str, list[dict[str, Any]]]:
    pages = results if isinstance(results, list) else [results]
    markdown_parts: list[str] = []
    blocks: list[dict[str, Any]] = []
    for page in pages:
        value = plain(page)
        markdown_value = value.get("markdown", {}) if isinstance(value, Mapping) else {}
        if isinstance(markdown_value, Mapping):
            markdown_parts.append(sanitize_markdown(markdown_value.get("markdown_texts", "")))
        else:
            markdown_parts.append(sanitize_markdown(markdown_value))
    markdown = "\n\n".join(part for part in markdown_parts if part)
    search_cursor = 0
    for page in pages:
        page_value = plain(page)
        page_markdown = ""
        if isinstance(page_value, Mapping):
            markdown_value = page_value.get("markdown", {})
            if isinstance(markdown_value, Mapping):
                page_markdown = sanitize_markdown(markdown_value.get("markdown_texts", ""))
            else:
                page_markdown = sanitize_markdown(markdown_value)
        blocks.extend(document_blocks(page, markdown, width, height, search_from=search_cursor))
        search_cursor += len(page_markdown)
    return markdown, blocks
