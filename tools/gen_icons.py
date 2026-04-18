#!/usr/bin/env python3
"""
Generate icon assets for the ezOS desktop.

The PSP/PS3-style look is composed from three layers at draw time:

    1. A solid rounded-rect "plate" in the icon's accent colour (drawn
       dynamically by Lua via ez.display.fill_round_rect).
    2. A white 48×48 glyph PNG centred over the plate.
    3. A shared 48×48 "shim" PNG that adds the vertical darkening gradient,
       top highlight, and subtle border.

Splitting the look this way means a single shim asset covers every icon,
tint colours live as integers in Lua, and experiments with colour never
require regenerating the glyph bitmaps.

Outputs written into lua/ezui/icons.lua:
    icons._shim            PNG bytes of the shared glass overlay (48×48).
    icons._plate_inset     pixels between slot edge and plate edge.
    icons._plate_radius    rounded-rect corner radius in pixels.
    icons._plate_size      plate side length in pixels.
    icons.<name>.sm        16×16 flat white glyph for list items.
    icons.<name>.lg        48×48 white glyph, transparent elsewhere.
    icons.<name>.color     RGB565 plate tint.
"""

import io
import urllib.request
from pathlib import Path

import cairosvg
from PIL import Image, ImageDraw, ImageFilter

# -----------------------------------------------------------------------------
# Icon catalogue
# -----------------------------------------------------------------------------

# (lucide_name, lua_key, plate_tint_rgb)
ICONS = [
    ("mail",          "mail",        (58, 140, 220)),
    ("users",         "users",       (220, 80, 70)),
    ("map",           "map",         (210, 135, 60)),
    ("grid-3x3",      "grid",        (120, 110, 180)),
    ("hash",          "hash",        (180, 100, 200)),
    ("radio-tower",   "radio_tower", (230, 110, 90)),
    ("folder",        "folder",      (220, 180, 80)),
    ("settings",      "settings",    (130, 140, 160)),
    ("terminal",      "terminal",    (60, 170, 150)),
    ("info",          "info",        (90, 150, 210)),
    ("message-square", "message",    (100, 180, 200)),
    ("globe",         "globe",       (60, 170, 90)),
    ("ellipsis",      "more_horiz",  (120, 120, 130)),
]

SVG_BASE_URL = "https://raw.githubusercontent.com/lucide-icons/lucide/main/icons/{name}.svg"

LG_SIZE = 48
SM_SIZE = 16
GLYPH_INSET = 10
PLATE_INSET = 4
PLATE_RADIUS = max(4, LG_SIZE // 6)
PLATE_SIZE = LG_SIZE - 2 * PLATE_INSET

# Focus glow is rendered behind the focused icon. Its canvas is larger than
# the plate so the blurred halo can spread beyond the plate edge.
GLOW_SIZE = LG_SIZE + 16
GLOW_PAD = (GLOW_SIZE - LG_SIZE) // 2


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

def rgb565(r: int, g: int, b: int) -> int:
    """Pack 8-bit-per-channel RGB into the panel's RGB565 layout."""
    return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)


def download_svg(name: str) -> bytes:
    url = SVG_BASE_URL.format(name=name)
    print(f"  fetching {url}")
    req = urllib.request.Request(url, headers={"User-Agent": "ezos-icon-gen/3.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read()


def svg_to_white_glyph(svg_bytes: bytes, size: int) -> Image.Image:
    """Rasterise SVG at (size, size), keep alpha, paint RGB fully white."""
    png = cairosvg.svg2png(bytestring=svg_bytes, output_width=size, output_height=size)
    img = Image.open(io.BytesIO(png)).convert("RGBA")
    pixels = img.load()
    for y in range(size):
        for x in range(size):
            _, _, _, a = pixels[x, y]
            pixels[x, y] = (255, 255, 255, a)
    return img


# -----------------------------------------------------------------------------
# Shim (shared glass overlay)
# -----------------------------------------------------------------------------

def make_shim() -> Image.Image:
    """Render the shared 48×48 glass overlay.

    Contents (all alpha-over the plate):
      - A vertical darkening ramp from transparent at the top to ~35% black
        at the bottom, giving depth.
      - A soft white highlight ellipse over the top third.
      - A faint white 1-px rounded border to crisp the edge.
    Everything is masked to the rounded-rect plate shape so the shim can be
    drawn on top of a rectangular plate without leaking corners.
    """
    size = LG_SIZE
    plate_box = (PLATE_INSET, PLATE_INSET,
                 size - PLATE_INSET, size - PLATE_INSET)

    # Darkening gradient
    grad = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grad)
    inner_h = size - 2 * PLATE_INSET
    for i in range(inner_h):
        t = i / max(1, inner_h - 1)
        alpha = int(90 * (t ** 1.6))
        gd.line(
            [(PLATE_INSET, PLATE_INSET + i),
             (size - PLATE_INSET, PLATE_INSET + i)],
            fill=(0, 0, 0, alpha),
        )

    # Top highlight
    hl = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    hd = ImageDraw.Draw(hl)
    hd.ellipse(
        (PLATE_INSET + 2, PLATE_INSET - size // 3,
         size - PLATE_INSET - 2, PLATE_INSET + size // 3),
        fill=(255, 255, 255, 120),
    )
    hl = hl.filter(ImageFilter.GaussianBlur(0.6))

    combined = Image.alpha_composite(grad, hl)

    # Mask to the plate's rounded rect so the overlay lines up with the plate.
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        plate_box, radius=PLATE_RADIUS, fill=255,
    )
    r, g, b, a = combined.split()
    from PIL import ImageChops
    a = ImageChops.multiply(a, mask)
    combined = Image.merge("RGBA", (r, g, b, a))

    # Subtle bright border on top.
    border = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(border).rounded_rectangle(
        plate_box, radius=PLATE_RADIUS,
        outline=(255, 255, 255, 70), width=1,
    )
    return Image.alpha_composite(combined, border)


# -----------------------------------------------------------------------------
# Per-icon glyphs
# -----------------------------------------------------------------------------

def make_glow() -> Image.Image:
    """Render the focus glow — a soft white rounded-rect halo on a
    transparent canvas, sized GLOW_SIZE so callers can draw it at
    (icon_x - GLOW_PAD, icon_y - GLOW_PAD) to sit behind a 48×48 plate."""
    img = Image.new("RGBA", (GLOW_SIZE, GLOW_SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.rounded_rectangle(
        (GLOW_PAD - 2, GLOW_PAD - 2,
         GLOW_SIZE - GLOW_PAD + 2, GLOW_SIZE - GLOW_PAD + 2),
        radius=PLATE_RADIUS + 2,
        fill=(255, 255, 255, 180),
    )
    return img.filter(ImageFilter.GaussianBlur(5))


def make_lg_glyph(svg_bytes: bytes) -> Image.Image:
    """48×48 RGBA, white glyph centred, transparent elsewhere."""
    glyph_size = LG_SIZE - 2 * GLYPH_INSET
    glyph = svg_to_white_glyph(svg_bytes, glyph_size)
    canvas = Image.new("RGBA", (LG_SIZE, LG_SIZE), (0, 0, 0, 0))
    pos = ((LG_SIZE - glyph_size) // 2, (LG_SIZE - glyph_size) // 2)
    canvas.paste(glyph, pos, glyph)
    return canvas


def make_sm_glyph(svg_bytes: bytes) -> Image.Image:
    return svg_to_white_glyph(svg_bytes, SM_SIZE)


# -----------------------------------------------------------------------------
# Lua emission
# -----------------------------------------------------------------------------

def png_bytes(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def to_lua_literal(data: bytes) -> str:
    return '"' + "".join(f"\\x{b:02x}" for b in data) + '"'


def main() -> None:
    out_path = Path(__file__).parent.parent / "lua" / "ezui" / "icons.lua"
    print(f"Generating icon assets -> {out_path}")

    svg_cache: dict[str, bytes] = {}
    for svg_name, _, _ in ICONS:
        svg_cache[svg_name] = download_svg(svg_name)

    print()
    shim_png = png_bytes(make_shim())
    glow_png = png_bytes(make_glow())
    print(f"  _shim (shared overlay): {len(shim_png):5d}B")
    print(f"  _glow (focus halo):     {len(glow_png):5d}B")

    lines = [
        "-- Desktop icon assets generated by tools/gen_icons.py.",
        "--",
        "-- Each icon ships two white glyph PNGs (sm = 16, lg = 48) plus an",
        "-- RGB565 accent colour used to tint the plate drawn behind the glyph.",
        "-- icons._shim is a shared 48×48 glass overlay composited on top of",
        "-- the plate and glyph to add depth (gradient, highlight, border).",
        "-- icons._glow is a pre-blurred white halo drawn behind the focused",
        "-- icon at (icon_x - _glow_pad, icon_y - _glow_pad).",
        "",
        "local icons = {}",
        "",
        f"icons._plate_inset  = {PLATE_INSET}",
        f"icons._plate_size   = {PLATE_SIZE}",
        f"icons._plate_radius = {PLATE_RADIUS}",
        f"icons._glow_pad     = {GLOW_PAD}",
        f"icons._shim = {to_lua_literal(shim_png)}",
        f"icons._glow = {to_lua_literal(glow_png)}",
        "",
    ]

    for svg_name, lua_name, tint in ICONS:
        svg = svg_cache[svg_name]
        sm_bytes = png_bytes(make_sm_glyph(svg))
        lg_bytes = png_bytes(make_lg_glyph(svg))
        color = rgb565(*tint)
        print(f"  {lua_name:15s} lg={len(lg_bytes):5d}B sm={len(sm_bytes):4d}B color=0x{color:04X}")

        lines.append(f"icons.{lua_name} = {{")
        lines.append(f"    sm = {to_lua_literal(sm_bytes)},")
        lines.append(f"    lg = {to_lua_literal(lg_bytes)},")
        lines.append(f"    color = 0x{color:04X},")
        lines.append("}")
        lines.append("")

    lines.append("return icons")
    lines.append("")

    out_path.write_text("\n".join(lines))
    total = out_path.stat().st_size
    print(f"\nWrote {out_path} ({total} bytes)")


if __name__ == "__main__":
    main()
