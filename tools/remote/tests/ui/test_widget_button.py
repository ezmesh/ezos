"""
button widget: renders a label inside a bordered rect, focusable.

Asserts the label text shows up in the captured frame. The button's
visual styling (rounded rect, focus ring) is covered indirectly via
the primitives capture; this test only checks the label so it remains
robust against theme changes.
"""

from __future__ import annotations


def test_button_renders_label(mounted):
    mounted("return ezui.button('Press me')")
    texts = mounted.device.wait_frame_text()
    labels = [t["text"] for t in texts]
    assert "Press me" in labels, f"button label missing from frame: {labels}"
