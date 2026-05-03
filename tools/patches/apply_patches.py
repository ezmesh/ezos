"""
Pre-build hook: apply local patches to third-party libraries.

PlatformIO regenerates `.pio/libdeps/` whenever a dep is reinstalled,
which wipes any direct edits we made to library source. Anything in
this file gets re-applied on every build, so the patches survive
reinstalls, fresh clones, and CI.

Each patch is implemented as a content-based search-and-inject rather
than a unified-diff `patch -p1` so it's tolerant of small upstream
churn (line numbers shifting, surrounding whitespace tweaks). Each
function is idempotent: if the marker comment is already in the file,
it's a no-op.

Hooked from platformio.ini via:
    extra_scripts = pre:tools/patches/apply_patches.py

To add a new patch: write a `_patch_<lib>_<area>(env)` function that
locates the file, checks for the marker, and edits if absent. Then
call it from `apply_patches(env)`.
"""

import os
import sys

Import("env")  # noqa: F821  (PlatformIO injects this)


def _libdeps_root(env):
    """Return the active env's libdeps directory (e.g. .pio/libdeps/t-deck-plus)."""
    project_dir = env.subst("$PROJECT_DIR")
    env_name = env["PIOENV"]
    return os.path.join(project_dir, ".pio", "libdeps", env_name)


def _patch_lgfx_alpha_null_check(env):
    """
    LovyanGFX v1: null-check the alpha-blend line buffer alloc.

    heap_alloc_dma() returns NULL when DMA-capable internal DRAM is
    exhausted (happens on ESP32-S3 the moment WiFi opens a TCP socket
    during a fetch). Upstream doesn't check, leading to a null-deref
    crash in bgra8888_t::set on Core 1. We add a guard so the row
    simply skips rendering instead.
    """
    path = os.path.join(
        _libdeps_root(env),
        "LovyanGFX", "src", "lgfx", "v1", "LGFXBase.cpp",
    )
    if not os.path.isfile(path):
        # Library not installed yet (clean build); PlatformIO will
        # install it after this script runs and re-trigger us. Bail
        # silently — the next pass picks it up.
        return

    with open(path, "r", encoding="utf-8") as f:
        src = f.read()

    marker = "ezOS patch: heap_alloc_dma can return null"
    if marker in src:
        return  # already applied

    needle = (
        "        if (p->lineBuffer == nullptr)\n"
        "        {\n"
        "          p->lineBuffer = (bgra8888_t*)heap_alloc_dma("
        "sizeof(bgra8888_t) * p->maxWidth);\n"
        "        }\n"
        "        p->gfx->readRect(p->x, p->y + y0, p->maxWidth, 1, "
        "p->lineBuffer);\n"
    )
    if needle not in src:
        sys.stderr.write(
            "[apply_patches] LGFX alpha guard: anchor not found in "
            f"{path} -- upstream code shape changed; review and update "
            "the patch.\n"
        )
        return

    replacement = (
        "        if (p->lineBuffer == nullptr)\n"
        "        {\n"
        "          p->lineBuffer = (bgra8888_t*)heap_alloc_dma("
        "sizeof(bgra8888_t) * p->maxWidth);\n"
        "        }\n"
        "        // ezOS patch: heap_alloc_dma can return null when WiFi has\n"
        "        // claimed DMA-capable DRAM during a fetch. The upstream code\n"
        "        // doesn't null-check, which crashes the next line with a\n"
        "        // null-deref in bgra8888_t::set. Skip the alpha-blend pass\n"
        "        // entirely if we have no line buffer -- the row just doesn't\n"
        "        // render this frame, which is a far better outcome than a\n"
        "        // hard reset.\n"
        "        if (p->lineBuffer == nullptr) return;\n"
        "        p->gfx->readRect(p->x, p->y + y0, p->maxWidth, 1, "
        "p->lineBuffer);\n"
    )
    src = src.replace(needle, replacement, 1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
    print(f"[apply_patches] applied LGFX alpha-null-check to {path}")


def apply_patches(env):
    _patch_lgfx_alpha_null_check(env)


apply_patches(env)  # noqa: F821
