#!/usr/bin/env python3
"""
Pre-process wallpapers for the T-Deck's RGB565 panel.

For every image in wallpapers-in/:
  1. Fit to 320x240 with a cover-style centre crop.
  2. Floyd–Steinberg dither into the RGB565 colour space the panel can
     actually show (5/6/5 bits per channel).
  3. Re-encode as JPEG at a moderate quality and write to data/wallpapers/.

Dithering before JPEG gives smoother gradients on the panel than either
letting the encoder quantise against the full 24-bit source or bit-masking
without error diffusion. File sizes typically stay within a few percent of
un-dithered output.

Usage:
    python tools/gen_wallpapers.py                   # batch wallpapers-in/
    python tools/gen_wallpapers.py <in> <out>        # single file
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

REPO_ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = REPO_ROOT / "wallpapers-in"
DST_DIR = REPO_ROOT / "data" / "wallpapers"

TARGET_W, TARGET_H = 320, 240
JPEG_QUALITY = 82


# -----------------------------------------------------------------------------
# Fit + crop
# -----------------------------------------------------------------------------

def fit_cover(img: Image.Image, w: int, h: int) -> Image.Image:
    """Scale and centre-crop `img` so it exactly fills (w, h)."""
    src_w, src_h = img.size
    scale = max(w / src_w, h / src_h)
    new_w, new_h = int(round(src_w * scale)), int(round(src_h * scale))
    img = img.resize((new_w, new_h), Image.LANCZOS)
    left = (new_w - w) // 2
    top = (new_h - h) // 2
    return img.crop((left, top, left + w, top + h))


# -----------------------------------------------------------------------------
# RGB565 Floyd–Steinberg dither
# -----------------------------------------------------------------------------

def rgb565_dither(img: Image.Image) -> Image.Image:
    """Quantise `img` to RGB565 with Floyd–Steinberg error diffusion.

    Working buffer is int16 so each pixel can temporarily over- or
    undershoot [0, 255] while accumulating neighbour error. We quantise in
    place row by row, clipping back to uint8 only at the end.
    """
    arr = np.asarray(img.convert("RGB"), dtype=np.int16).copy()
    h, w, _ = arr.shape

    for y in range(h):
        for x in range(w):
            # Accumulated neighbour error can push the buffer value outside
            # [0, 255]; clip before masking so the bitwise AND doesn't sign-
            # extend a negative int16 into a bogus "nearest colour" and
            # spray a feedback loop across the image.
            old = np.clip(arr[y, x], 0, 255).astype(np.int16)
            new = np.array([
                int(old[0]) & 0xF8,   # 5-bit red
                int(old[1]) & 0xFC,   # 6-bit green
                int(old[2]) & 0xF8,   # 5-bit blue
            ], dtype=np.int16)
            err = old - new
            arr[y, x] = new

            # Error diffusion: 7/16 right, 3/16 down-left, 5/16 down, 1/16 down-right
            if x + 1 < w:
                arr[y, x + 1] += err * 7 // 16
            if y + 1 < h:
                if x > 0:
                    arr[y + 1, x - 1] += err * 3 // 16
                arr[y + 1, x] += err * 5 // 16
                if x + 1 < w:
                    arr[y + 1, x + 1] += err * 1 // 16

    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB")


# -----------------------------------------------------------------------------
# Pipeline
# -----------------------------------------------------------------------------

def process_one(src: Path, dst: Path, quality: int = JPEG_QUALITY) -> tuple[int, int]:
    img = Image.open(src)
    # Strip EXIF orientation so phone photos land right-way-up.
    img = img.convert("RGB")
    if hasattr(img, "_getexif"):
        try:
            from PIL import ImageOps
            img = ImageOps.exif_transpose(img)
        except Exception:
            pass

    fitted = fit_cover(img, TARGET_W, TARGET_H)
    dithered = rgb565_dither(fitted)

    dst.parent.mkdir(parents=True, exist_ok=True)
    dithered.save(dst, "JPEG", quality=quality, optimize=True)

    src_bytes = src.stat().st_size
    dst_bytes = dst.stat().st_size
    return src_bytes, dst_bytes


def iter_inputs(src_dir: Path):
    """Yield image files from `src_dir`, sorted, filtered by extension."""
    exts = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}
    for p in sorted(src_dir.iterdir()):
        if p.is_file() and p.suffix.lower() in exts:
            yield p


def main() -> None:
    ap = argparse.ArgumentParser(description="Quantise + dither wallpapers for RGB565")
    ap.add_argument("input", nargs="?", type=Path, help="single input image")
    ap.add_argument("output", nargs="?", type=Path, help="single output path")
    ap.add_argument("-q", "--quality", type=int, default=JPEG_QUALITY,
                    help=f"JPEG quality (default {JPEG_QUALITY})")
    ap.add_argument("--src", type=Path, default=SRC_DIR,
                    help=f"batch source dir (default {SRC_DIR.relative_to(REPO_ROOT)})")
    ap.add_argument("--dst", type=Path, default=DST_DIR,
                    help=f"batch output dir (default {DST_DIR.relative_to(REPO_ROOT)})")
    ap.add_argument("--rename", metavar="PREFIX",
                    help="batch: rename outputs PREFIX01.jpg..PREFIXNN.jpg by sort order")
    args = ap.parse_args()

    if args.input and args.output:
        src_b, dst_b = process_one(args.input, args.output, args.quality)
        print(f"{args.input} -> {args.output}  {src_b} -> {dst_b} bytes")
        return

    if args.input or args.output:
        ap.error("pass BOTH input and output, or neither (for batch mode)")

    # Batch mode.
    if not args.src.exists():
        sys.exit(f"source directory not found: {args.src}")

    files = list(iter_inputs(args.src))
    if not files:
        sys.exit(f"no images in {args.src}")

    print(f"Processing {len(files)} files from {args.src} -> {args.dst}")
    total_in = total_out = 0
    for i, src in enumerate(files, start=1):
        if args.rename:
            stem = f"{args.rename}{i:02d}"
        else:
            stem = src.stem
        dst = args.dst / (stem + ".jpg")
        src_b, dst_b = process_one(src, dst, args.quality)
        label = f"{src.name[:28]:<28s} -> {dst.name}"
        total_in += src_b
        total_out += dst_b
        print(f"  [{i:2d}/{len(files)}] {label}  {src_b:>8d}B -> {dst_b:>6d}B")

    saved = total_in - total_out
    pct = 100 * saved / total_in if total_in else 0
    print(f"\nTotal: {total_in} -> {total_out} bytes (saved {saved}, {pct:.1f}%)")


if __name__ == "__main__":
    main()
