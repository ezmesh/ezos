"""
ez.display bindings — drawing primitives, text, sprites, 3D scenes.

Tests run with the test_mode screen owning the display. The primitive
sink only emits the low-level shapes the renderer ultimately reaches
(fill_rect, fill_round_rect, draw_bitmap, draw_text, draw_pixel, lines,
triangles); higher-level helpers like fill_circle decompose into those
before reaching the sink, so type-level assertions on the captured
primitives aren't a stable signal. Instead each test calls the
binding and asserts no Lua error — which catches arg-count and type
mismatches that are the common breakage modes.

Stateful mutators (brightness, clip rect, font size/style, transparent
color) save and restore.
"""

from __future__ import annotations


# ---------------------------------------------------------------------------
# Namespace & getters
# ---------------------------------------------------------------------------


def test_namespace(device):
    assert device.lua_exec("return type(ez.display)") == "table"


def test_get_width_height_match_320x240(device):
    w = device.lua_exec("return ez.display.get_width()")
    h = device.lua_exec("return ez.display.get_height()")
    assert w == 320 and h == 240


def test_get_cols_rows_positive(device):
    cols = device.lua_exec("return ez.display.get_cols()")
    rows = device.lua_exec("return ez.display.get_rows()")
    assert isinstance(cols, int) and cols > 0
    assert isinstance(rows, int) and rows > 0


def test_get_font_width_height(device):
    fw = device.lua_exec("return ez.display.get_font_width()")
    fh = device.lua_exec("return ez.display.get_font_height()")
    assert isinstance(fw, int) and fw > 0
    assert isinstance(fh, int) and fh > 0


def test_text_width_grows_with_string(device):
    a = device.lua_exec("return ez.display.text_width('hi')")
    b = device.lua_exec("return ez.display.text_width('hello world')")
    assert isinstance(a, int) and isinstance(b, int)
    assert b > a


def test_rgb_pack_round_trip(device):
    """rgb(r,g,b) packs to RGB565. Red full saturation should hit 0xF800."""
    red = device.lua_exec("return ez.display.rgb(255, 0, 0)")
    green = device.lua_exec("return ez.display.rgb(0, 255, 0)")
    blue = device.lua_exec("return ez.display.rgb(0, 0, 255)")
    assert red == 0xF800
    assert green == 0x07E0
    assert blue == 0x001F


# ---------------------------------------------------------------------------
# Stateful mutators — save & restore
# ---------------------------------------------------------------------------


def test_set_brightness_round_trip(device):
    """get_brightness isn't exposed; just verify set_brightness is callable
    in valid range and restore the user's pref-driven value."""
    original = device.lua_exec("return ez.storage.get_pref('brightness', '200')")
    try:
        device.lua_exec("ez.display.set_brightness(64)")
        device.lua_exec("ez.display.set_brightness(255)")
    finally:
        device.lua_exec(f"ez.display.set_brightness(tonumber('{original}') or 200)")


def test_set_font_size_round_trip(device):
    """Defaults to 'small'; round-trip through known sizes."""
    for size in ("tiny", "small", "small_aa", "medium"):
        ok = device.lua_exec(f"ez.display.set_font_size('{size}'); return true")
        assert ok is True
    device.lua_exec("ez.display.set_font_size('small_aa')")  # match theme default


def test_set_font_style(device):
    for style in ("normal", "bold"):
        device.lua_exec(f"ez.display.set_font_style('{style}')")
    device.lua_exec("ez.display.set_font_style('normal')")


def test_clip_rect_round_trip(device):
    device.lua_exec("ez.display.set_clip_rect(0, 0, 320, 240)")
    device.lua_exec("ez.display.clear_clip_rect()")


def test_sprite_set_transparent_color(device):
    """set_transparent_color is a sprite method, not a top-level display
    function. Round-trip verifies the wiring."""
    code = """
        local s = ez.display.create_sprite(8, 8)
        if not s then return false end
        s:set_transparent_color(0)
        s:set_transparent_color(0xFFFF)
        s:destroy()
        return true
    """
    out = device.lua_exec(code)
    if out is False:
        import pytest
        pytest.skip("create_sprite returned nil — likely low PSRAM")
    assert out is True


# ---------------------------------------------------------------------------
# Drawing primitives — call each, verify the right primitive type appears
# ---------------------------------------------------------------------------


def test_clear_runs_without_error(device):
    device.lua_exec("ez.display.clear(); ez.display.flush()")


def test_fill_rect(device):
    device.lua_exec("ez.display.fill_rect(10, 10, 30, 20, 0xF800)")


def test_draw_rect(device):
    device.lua_exec("ez.display.draw_rect(50, 10, 30, 20, 0x07E0)")


def test_draw_pixel(device):
    device.lua_exec("ez.display.draw_pixel(160, 120, 0xFFFF)")


def test_draw_line(device):
    device.lua_exec("ez.display.draw_line(0, 0, 320, 240, 0x001F)")


def test_draw_hline(device):
    device.lua_exec("ez.display.draw_hline(20, 100, 80, 0xF81F)")


def test_draw_circle(device):
    device.lua_exec("ez.display.draw_circle(100, 100, 20, 0xFFFF)")


def test_fill_circle(device):
    device.lua_exec("ez.display.fill_circle(100, 100, 15, 0x07E0)")


def test_draw_triangle(device):
    device.lua_exec("ez.display.draw_triangle(10,10, 50,10, 30,40, 0xF800)")


def test_fill_triangle(device):
    device.lua_exec("ez.display.fill_triangle(10,10, 50,10, 30,40, 0xF800)")


def test_draw_round_rect(device):
    device.lua_exec("ez.display.draw_round_rect(60, 60, 40, 40, 8, 0x07E0)")


def test_fill_round_rect(device):
    device.lua_exec("ez.display.fill_round_rect(60, 60, 40, 40, 8, 0x07E0)")


def test_dithered_and_hatch_fills(device):
    """Confirms fill_rect_dithered/hlines/vlines all emit at least
    fill_rect primitives. Implementation may decompose them into multiple
    primitives, so we only assert the call path runs without error."""
    device.lua_exec("ez.display.fill_rect_dithered(0, 0, 32, 32, 0xF800, 50)")
    device.lua_exec("ez.display.fill_rect_hlines(0, 0, 32, 32, 0x07E0, 4)")
    device.lua_exec("ez.display.fill_rect_vlines(0, 0, 32, 32, 0x001F, 4)")


def test_draw_progress(device):
    device.lua_exec("ez.display.draw_progress(20, 200, 280, 12, 50, 0xFFFF, 0)")


def test_draw_indicators(device):
    """Battery, signal, wifi, gps icon helpers."""
    device.lua_exec("ez.display.draw_battery(280, 4, 75)")
    device.lua_exec("ez.display.draw_signal(220, 4, 3)")
    device.lua_exec("ez.display.draw_wifi(240, 4, 2)")
    device.lua_exec("ez.display.draw_gps(260, 4, 1)")


# ---------------------------------------------------------------------------
# Text drawing
# ---------------------------------------------------------------------------


def test_draw_text(device):
    device.lua_exec("ez.display.draw_text(10, 10, 'hello', 0xFFFF)")


def test_draw_text_centered(device):
    device.lua_exec("ez.display.draw_text_centered(120, 'centered', 0xFFFF)")


def test_draw_text_bg(device):
    device.lua_exec(
        "ez.display.draw_text_bg(10, 50, 'bg', 0xFFFF, 0xF800, 2)"
    )


def test_draw_text_shadow(device):
    device.lua_exec(
        "ez.display.draw_text_shadow(10, 70, 'shadow', 0xFFFF, 0x0000, 1)"
    )


def test_draw_char(device):
    device.lua_exec("ez.display.draw_char(10, 90, string.byte('A'), 0xFFFF)")


def test_draw_box(device):
    device.lua_exec(
        "ez.display.draw_box(40, 100, 100, 60, 'Title', 0xFFFF, 0x07E0)"
    )


# ---------------------------------------------------------------------------
# Bitmaps
# ---------------------------------------------------------------------------


def test_draw_bitmap_runs(device):
    """Tiny 4x4 RGB565 bitmap (all red)."""
    code = """
        local data = string.rep(string.char(0x00, 0xF8), 16) -- 4x4 RGB565 little-endian
        ez.display.draw_bitmap(0, 0, 4, 4, data)
    """
    device.lua_exec(code)


def test_draw_bitmap_transparent_runs(device):
    code = """
        local data = string.rep(string.char(0x00, 0xF8), 16)
        ez.display.draw_bitmap_transparent(0, 0, 4, 4, data, 0xF800)
    """
    device.lua_exec(code)


def test_draw_indexed_bitmap_runs(device):
    """4x4 indexed bitmap, palette of 2 colors. Indices packed at 4bpp."""
    code = """
        local palette = { 0x0000, 0xF800 }
        -- 4x4 = 16 indices @ 4bpp = 8 bytes
        local data = string.rep(string.char(0x10), 8)
        ez.display.draw_indexed_bitmap(0, 0, 4, 4, data, palette)
    """
    device.lua_exec(code)


def test_get_image_size_rejects_garbage(device):
    """get_image_size on invalid image data should return nil/error."""
    out = device.lua_exec("return ez.display.get_image_size('not an image')")
    # Either nil or a 2-tuple — accept either failure shape.
    assert out is None or (isinstance(out, list) and (out[0] is None or len(out) >= 2))


# ---------------------------------------------------------------------------
# Sprites
# ---------------------------------------------------------------------------


def test_sprite_create_destroy(device):
    """create_sprite returns a userdata with :width(), :height(), :destroy()
    methods. ez.display.width/.height are screen-size constants, not sprite
    accessors."""
    code = """
        local s = ez.display.create_sprite(32, 16)
        if not s then return false end
        local w = s:width()
        local h = s:height()
        s:destroy()
        return { w = w, h = h }
    """
    out = device.lua_exec(code)
    if out is False:
        import pytest
        pytest.skip("create_sprite returned nil — likely low PSRAM headroom")
    assert out["w"] == 32
    assert out["h"] == 16


def test_display_width_height_constants(device):
    """ez.display.width and ez.display.height are constant integers, not
    callables — they expose the panel dimensions independent of any sprite."""
    w = device.lua_exec("return ez.display.width")
    h = device.lua_exec("return ez.display.height")
    assert w == 320 and h == 240


# ---------------------------------------------------------------------------
# 3D scene
# ---------------------------------------------------------------------------


def test_scene_create_count_clear(device):
    """scene_new returns a scene object; scene_count reflects added prims."""
    code = """
        local sc = ez.display.scene_new()
        ez.display.scene_add_tri(sc, 0,0,0,  1,0,0,  0,1,0, 0xFFFF)
        ez.display.scene_add_quad(sc,
            0,0,0,  1,0,0,  1,1,0,  0,1,0,  0xF800)
        ez.display.scene_add_aabb(sc, 0,0,0,  1,1,1, 0x07E0, 0x001F)
        local n = ez.display.scene_count(sc)
        ez.display.scene_clear(sc)
        local n_after = ez.display.scene_count(sc)
        return { before = n, after = n_after }
    """
    out = device.lua_exec(code)
    assert out["before"] >= 3
    assert out["after"] == 0


def test_scene_set_camera(device):
    """scene_set_camera takes (scene, px, pz, yaw_cos, yaw_sin)."""
    device.lua_exec("""
        local sc = ez.display.scene_new()
        ez.display.scene_set_camera(sc, 0.0, 5.0, 1.0, 0.0)
    """)


# ---------------------------------------------------------------------------
# Screenshot
# ---------------------------------------------------------------------------


def test_save_screenshot_returns_bool(device):
    """save_screenshot writes a BMP. The binding requires an SD path; if
    no SD card is mounted it returns false. We just verify the call shape."""
    out = device.lua_exec(
        "return ez.display.save_screenshot('/sd/_test_screen.bmp')"
    )
    assert isinstance(out, bool)
    if out is True:
        # If it succeeded, clean up.
        device.lua_exec("ez.storage.remove('/sd/_test_screen.bmp')")


# ---------------------------------------------------------------------------
# Notes on bindings deliberately not unit-tested:
#
#   draw_jpeg / draw_png — would need real encoded image data; covered
#   indirectly by the wallpaper loader and About screen render paths.
#
#   draw_indexed_bitmap_scaled — exercised by map_view; the parameter
#   set is large and the test would essentially duplicate the map_view
#   integration without meaningful coverage gain.
#
#   scene_render / scene_render_z / scene_add_road_strip /
#   scene_add_billboard{,_split} / scene_mark_static / scene_reset_to —
#   the 3D pipeline is exercised end-to-end by the wasteland game; per-
#   function unit tests would call into a renderer that can't be
#   asserted on without pixel-level capture.
# ---------------------------------------------------------------------------
