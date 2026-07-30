#!/usr/bin/env python3
"""Regenerate Resources/Assets.xcassets/AppIcon.appiconset from the hammer glyph.

The container (mint squircle) is drawn to Apple's macOS icon geometry rather than
resampled from the original artwork: a 824x824 body centred on a 1024x1024 canvas
with a continuous-corner (superellipse) profile. Each size is rendered from scratch
so small variants stay crisp instead of accumulating resampling softness.

Usage: python3 scripts/generate-app-icon.py
"""
from __future__ import annotations

import json
import pathlib

import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
GLYPH = ROOT / "Resources/AppIcon/hammer-glyph.png"
OUT = ROOT / "Resources/Assets.xcassets/AppIcon.appiconset"

# --- Geometry (fractions of the full canvas) --------------------------------
BODY = 824 / 1024          # Apple's macOS body size inside the icon canvas
CORNER_N = 5.0             # superellipse exponent ~ macOS continuous corner
GLYPH_H = 0.723            # glyph height / body height, measured from the source
GLYPH_DY = 0.033           # glyph sits slightly below body centre, as designed
SUPERSAMPLE = 8            # mask antialiasing factor

# --- Colour: vertical gradient sampled from the source artwork ---------------
TOP = np.array([244.0, 255.0, 249.0])
BOTTOM = np.array([231.0, 249.0, 240.0])

# (size, scale) pairs required for a macOS app icon set.
VARIANTS = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]


def body_alpha(px: int) -> np.ndarray:
    """Supersampled coverage mask for the rounded body, as float 0..1 at px*px."""
    ss = px * SUPERSAMPLE
    # Sample at pixel centres in canvas space (-1..1 across the body).
    t = (np.arange(ss, dtype=np.float64) + 0.5) / ss  # 0..1 over the canvas
    u = (t - 0.5) * 2.0 / BODY                        # -1..1 at the body edge
    ux = np.abs(u)[None, :] ** CORNER_N
    uy = np.abs(u)[:, None] ** CORNER_N
    inside = (ux + uy) <= 1.0
    cov = inside.astype(np.float32)
    # Box-average the supersampled grid down to the target resolution.
    return cov.reshape(px, SUPERSAMPLE, px, SUPERSAMPLE).mean(axis=(1, 3))


def render(px: int, glyph_src: Image.Image) -> Image.Image:
    alpha = body_alpha(px)

    # Vertical gradient across the body only, so the ramp matches the source
    # regardless of the transparent margin.
    rows = np.arange(px, dtype=np.float64)
    lo = (1.0 - BODY) / 2.0 * px
    g = np.clip((rows - lo) / (BODY * px), 0.0, 1.0)[:, None]
    rgb = TOP[None, :] * (1.0 - g) + BOTTOM[None, :] * g       # px x 3
    canvas = np.repeat(rgb[:, None, :], px, axis=1)            # px x px x 3

    out = np.dstack([canvas, alpha[:, :, None] * 255.0]).astype(np.uint8)
    img = Image.fromarray(out, "RGBA")

    # Glyph: scale to the measured proportion of the body, keep pure black.
    gh = GLYPH_H * BODY * px
    gw = gh * glyph_src.width / glyph_src.height
    gw_i, gh_i = max(1, round(gw)), max(1, round(gh))
    glyph = glyph_src.resize((gw_i, gh_i), Image.LANCZOS)

    cx = px / 2.0
    cy = px / 2.0 + GLYPH_DY * BODY * px
    img.alpha_composite(glyph, (round(cx - gw_i / 2), round(cy - gh_i / 2)))
    return img


def main() -> None:
    glyph_src = Image.open(GLYPH).convert("RGBA")
    OUT.mkdir(parents=True, exist_ok=True)

    images = []
    for size, scale in VARIANTS:
        px = size * scale
        name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
        render(px, glyph_src).save(OUT / name, optimize=True)
        images.append({
            "idiom": "mac",
            "size": f"{size}x{size}",
            "scale": f"{scale}x",
            "filename": name,
        })
        print(f"  {name:24s} {px}x{px}")

    contents = {"images": images, "info": {"version": 1, "author": "xcode"}}
    (OUT / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
