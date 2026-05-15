"""
vbox layout node: one of the foundational layout primitives in ezui.

Mounts a vbox with three labelled text children and asserts that:
- All three labels show up in the rendered text frame.
- Children are stacked top-to-bottom: y(A) < y(B) < y(C).
"""

from __future__ import annotations


def test_vbox_stacks_children_vertically(mounted):
    mounted(
        "return ezui.vbox({gap = 4}, {"
        " ezui.text_widget('A'),"
        " ezui.text_widget('B'),"
        " ezui.text_widget('C'),"
        "})"
    )
    texts = mounted.device.wait_frame_text()
    by_label = {t["text"]: t for t in texts if t["text"] in ("A", "B", "C")}
    assert set(by_label) == {"A", "B", "C"}, (
        f"missing one of the children in the frame; got {sorted(by_label)}"
    )
    ya, yb, yc = by_label["A"]["y"], by_label["B"]["y"], by_label["C"]["y"]
    assert ya < yb < yc, f"vbox did not stack top-to-bottom: y={ya},{yb},{yc}"
