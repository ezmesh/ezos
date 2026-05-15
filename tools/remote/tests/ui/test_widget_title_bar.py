"""
title_bar widget: a small bar at the top of a screen with optional back
chevron + right-side text. The widget itself does NOT render the title
string into the canvas — the global screen chrome handles that. What
this widget does render is:

- the literal string "Back" when `back = true`
- the `right` prop string when set
- a 1px bottom border line

Tests stick to those observables.
"""

from __future__ import annotations


def test_title_bar_renders_back_label(mounted):
    mounted("return ezui.title_bar('Some title', {back = true})")
    texts = mounted.device.wait_frame_text()
    labels = [t["text"] for t in texts]
    assert "Back" in labels, f"expected 'Back' label, got {labels}"


def test_title_bar_renders_right_text(mounted):
    mounted("return ezui.title_bar('Some title', {right = 'OK'})")
    texts = mounted.device.wait_frame_text()
    labels = [t["text"] for t in texts]
    assert "OK" in labels, f"expected right-side 'OK', got {labels}"


def test_title_bar_omits_back_when_not_set(mounted):
    mounted("return ezui.title_bar('Some title', {})")
    texts = mounted.device.wait_frame_text()
    labels = [t["text"] for t in texts]
    assert "Back" not in labels, (
        f"'Back' rendered even though back=false; full frame text: {labels}"
    )
