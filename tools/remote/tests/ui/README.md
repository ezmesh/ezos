# Per-element UI tests

Tests under this directory exercise individual ezui elements in isolation,
rather than only through full-screen flows. The harness mounts a single
widget (or a small composed tree) on a dedicated fixture screen, captures
the next rendered frame, and asserts on the text or draw primitives.

## How it works

1. **Fixture screen** — `lua/screens/ui_fixture.lua`, a fullscreen
   chrome-free screen whose `build()` consults `_G._ui_fixture_build`
   for the widget tree to render.
2. **`mounted` fixture** — `conftest.py` here exposes a `mounted`
   pytest fixture that takes a Lua expression returning a widget node,
   pushes the fixture screen, forces one frame render, and surfaces
   any Lua build error as a test failure.
3. **Frame capture** — the test calls `mounted.device.wait_frame_text()`
   or `wait_frame_primitives()` (see `tools/remote/ez_remote.py`) and
   asserts on the result.

A minimal test:

```python
def test_button_renders_label(mounted):
    mounted("return ezui.button('Hi')")
    texts = mounted.device.wait_frame_text()
    assert any(t['text'] == 'Hi' for t in texts)
```

The harness inherits the session-level `device` fixture from
`tools/remote/tests/conftest.py`, so tests skip cleanly when no T-Deck
is connected. There is no host-side simulator; the issue mentions
`tools/simulator/` but that directory does not exist today, and the
device is currently the only place ezui actually runs.

## Running

```bash
# All UI element tests (requires T-Deck on /dev/ttyACM0)
pytest tools/remote/tests/ui/

# Single element
pytest tools/remote/tests/ui/test_widget_button.py

# Different port
EZ_REMOTE_PORT=/dev/ttyACM1 pytest tools/remote/tests/ui/
```

CI skips the whole tree when no device is present (the parent
`conftest.py` checks `EZ_REMOTE_PORT`).

## What's covered

This first cut establishes the harness plus one representative test
per element category. Filling in the remaining elements is incremental
follow-up work — each is a small file modelled after the three already
here.

### Layout nodes (`lua/ezui/layout.lua`)

- [x] `vbox` — `test_layout_vbox.py`
- [ ] `hbox`
- [ ] `zstack`
- [ ] `padding`
- [ ] `scroll`
- [ ] `spacer`
- [ ] `divider`

### Core widgets (`lua/ezui/widgets.lua`)

- [x] `button` — `test_widget_button.py`
- [x] `title_bar` — `test_widget_title_bar.py`
- [ ] `text` / `text_widget`
- [ ] `toggle`
- [ ] `text_input`
- [ ] `dropdown`
- [ ] `list_item`
- [ ] `progress`
- [ ] `status_bar`
- [ ] `spinner`
- [ ] `slider`
- [ ] `rich_text`

### Composite widgets (`lua/ezui/widgets/`)

- [ ] `map_view` — needs a mounted SD card with at least one `.tdmap`
      archive plus a hardware-QA pass; the harness can mount the
      widget but per-tile rendering depends on the loaded archive.

## Writing a new element test

1. Pick the element. Find its constructor in `widgets.lua` /
   `layout.lua` (e.g. `ezui.toggle(label, value, props)`).
2. Identify one or two observables — what text it renders, what
   `wait_frame_primitives()` shape it produces. Read the `draw`
   function in `node.register("<name>", { ... })` if unsure.
3. Add a `test_widget_<name>.py` or `test_layout_<name>.py` here.
   Mirror the style of the three existing tests: one Lua expression
   per `mounted()` call, one or two asserts.
4. Tick the checkbox above when the file lands.
