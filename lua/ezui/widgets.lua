-- ezui.widgets: All UI widgets
-- Each widget is a node type registered with the node system.

local node = require("ezui.node")
local theme = require("ezui.theme")
local text_util = require("ezui.text")
local focus_mod = require("ezui.focus")

local W = {}

-- ---------------------------------------------------------------------------
-- Text: static text display with optional wrapping
-- ---------------------------------------------------------------------------

node.register("text", {
    measure = function(n, max_w, max_h)
        local font = n.font or "medium"
        theme.set_font(font)
        local fh = theme.font_height()
        local str = n.value or ""

        if n.wrap then
            local lines = text_util.wrap(str, max_w)
            n._lines = lines
            local max_line_w = 0
            for _, line in ipairs(lines) do
                local lw = theme.text_width(line)
                if lw > max_line_w then max_line_w = lw end
            end
            return max_w, #lines * fh
        else
            return theme.text_width(str), fh
        end
    end,

    draw = function(n, d, x, y, w, h)
        local font = n.font or "medium"
        theme.set_font(font)
        local color = theme.color(n.color or "TEXT")
        local fh = theme.font_height()

        if n._lines then
            for i, line in ipairs(n._lines) do
                local lx = x
                if n.text_align == "center" then
                    lx = x + math.floor((w - theme.text_width(line)) / 2)
                elseif n.text_align == "right" then
                    lx = x + w - theme.text_width(line)
                end
                d.draw_text(lx, y + (i - 1) * fh, line, color)
            end
        else
            local str = n.value or ""
            if theme.text_width(str) > w then
                str = text_util.truncate(str, w)
            end
            local lx = x
            if n.text_align == "center" then
                lx = x + math.floor((w - theme.text_width(str)) / 2)
            elseif n.text_align == "right" then
                lx = x + w - theme.text_width(str)
            end
            d.draw_text(lx, y, str, color)
        end
    end,
})

-- ---------------------------------------------------------------------------
-- Button: clickable button with rounded border
-- ---------------------------------------------------------------------------

node.register("button", {
    focusable = true,

    measure = function(n, max_w, max_h)
        theme.set_font(n.font or "medium")
        local tw = theme.text_width(n.label or "")
        local pad_x = 16
        local pad_y = 6
        return math.min(tw + pad_x * 2, max_w), theme.font_height() + pad_y * 2
    end,

    draw = function(n, d, x, y, w, h)
        local focused = n._focused
        local bg = focused and theme.color("ACCENT") or theme.color("SURFACE")
        local fg = focused and theme.color("BG") or theme.color("TEXT")
        local border = focused and theme.color("ACCENT") or theme.color("BORDER")

        d.fill_round_rect(x, y, w, h, 4, bg)
        d.draw_round_rect(x, y, w, h, 4, border)

        theme.set_font(n.font or "medium")
        local label = n.label or ""
        local tw = theme.text_width(label)
        local tx = x + math.floor((w - tw) / 2)
        local ty = y + math.floor((h - theme.font_height()) / 2)
        d.draw_text(tx, ty, label, fg)
    end,

    on_activate = function(n, key)
        if n.on_press then n.on_press() end
        return "handled"
    end,
})

-- ---------------------------------------------------------------------------
-- Toggle: on/off switch with label
-- ---------------------------------------------------------------------------

node.register("toggle", {
    focusable = true,

    measure = function(n, max_w, max_h)
        theme.set_font("medium")
        local label_w = 0
        if n.label then label_w = theme.text_width(n.label) + 8 end
        local switch_w = 32
        local h = math.max(theme.font_height(), 16)
        return math.min(label_w + switch_w, max_w), h
    end,

    draw = function(n, d, x, y, w, h)
        local focused = n._focused
        local on = n.value or false
        theme.set_font("medium")

        -- Label
        if n.label then
            local fg = focused and theme.color("ACCENT") or theme.color("TEXT")
            d.draw_text(x, y + math.floor((h - theme.font_height()) / 2), n.label, fg)
        end

        -- Switch track
        local sw, sh = 28, 14
        local sx = x + w - sw
        local sy = y + math.floor((h - sh) / 2)
        local track_color = on and theme.color("SUCCESS") or theme.color("SURFACE_ALT")
        d.fill_round_rect(sx, sy, sw, sh, 7, track_color)
        if focused then
            d.draw_round_rect(sx, sy, sw, sh, 7, theme.color("ACCENT"))
        end

        -- Switch knob
        local knob_r = 5
        local knob_x = on and (sx + sw - knob_r - 3) or (sx + knob_r + 3)
        local knob_y = sy + math.floor(sh / 2)
        d.fill_circle(knob_x, knob_y, knob_r, theme.color("TEXT"))
    end,

    on_activate = function(n, key)
        n.value = not n.value
        if n.on_change then n.on_change(n.value) end
        return "handled"
    end,
})

-- ---------------------------------------------------------------------------
-- TextInput: single-line text entry
-- ---------------------------------------------------------------------------

node.register("text_input", {
    focusable = true,

    measure = function(n, max_w, max_h)
        theme.set_font("medium")
        return max_w, theme.font_height() + 8
    end,

    draw = function(n, d, x, y, w, h)
        local focused = n._focused
        local editing = focused and focus_mod.editing
        local bg = theme.color("SURFACE")
        local border = editing and theme.color("ACCENT")
                       or focused and theme.color("ACCENT_DIM")
                       or theme.color("BORDER")

        d.fill_round_rect(x, y, w, h, 3, bg)
        d.draw_round_rect(x, y, w, h, 3, border)

        theme.set_font("medium")
        local fh = theme.font_height()
        local tx = x + 4
        local ty = y + math.floor((h - fh) / 2)
        local val = n.value or ""
        local cursor_pos = n._cursor or #val

        if val == "" and n.placeholder and not editing then
            d.draw_text(tx, ty, n.placeholder, theme.color("TEXT_MUTED"))
        else
            local display_val = n.password and string.rep("*", #val) or val
            -- Scroll text if wider than field
            local avail = w - 8
            local full_w = theme.text_width(display_val)
            local scroll = 0
            if full_w > avail then
                -- Ensure cursor is visible
                local before_cursor = display_val:sub(1, cursor_pos)
                local cw = theme.text_width(before_cursor)
                scroll = math.max(0, cw - avail + 8)
            end

            d.set_clip_rect(x + 2, y, w - 4, h)
            d.draw_text(tx - scroll, ty, display_val, theme.color("TEXT"))
            d.clear_clip_rect()

            -- Cursor
            if editing then
                local before = display_val:sub(1, cursor_pos)
                local cx = tx - scroll + theme.text_width(before)
                local blink = math.floor(ez.system.millis() / 500) % 2 == 0
                if blink then
                    d.fill_rect(cx, ty, 2, fh, theme.color("ACCENT"))
                end
            end
        end
    end,

    on_activate = function(n, key)
        if not focus_mod.editing then
            focus_mod.enter_edit()
            n._cursor = #(n.value or "")
            return "handled"
        end
    end,

    on_key = function(n, key)
        if not focus_mod.editing then return nil end

        local val = n.value or ""
        local cursor = n._cursor or #val

        if key.special == "ESCAPE" then
            focus_mod.exit_edit()
            return "handled"
        elseif key.special == "ENTER" then
            focus_mod.exit_edit()
            if n.on_submit then n.on_submit(val) end
            return "handled"
        elseif key.special == "BACKSPACE" then
            if cursor > 0 then
                n.value = val:sub(1, cursor - 1) .. val:sub(cursor + 1)
                n._cursor = cursor - 1
                if n.on_change then n.on_change(n.value) end
            end
            return "handled"
        elseif key.special == "DELETE" then
            if cursor < #val then
                n.value = val:sub(1, cursor) .. val:sub(cursor + 2)
                if n.on_change then n.on_change(n.value) end
            end
            return "handled"
        elseif key.special == "LEFT" then
            if cursor > 0 then n._cursor = cursor - 1 end
            return "handled"
        elseif key.special == "RIGHT" then
            if cursor < #val then n._cursor = cursor + 1 end
            return "handled"
        elseif key.special == "HOME" then
            n._cursor = 0
            return "handled"
        elseif key.special == "END" then
            n._cursor = #val
            return "handled"
        elseif key.character then
            local max = n.max_length or 256
            if #val < max then
                n.value = val:sub(1, cursor) .. key.character .. val:sub(cursor + 1)
                n._cursor = cursor + 1
                if n.on_change then n.on_change(n.value) end
            end
            return "handled"
        end

        return nil
    end,
})

-- ---------------------------------------------------------------------------
-- Dropdown: collapsible select
-- ---------------------------------------------------------------------------

node.register("dropdown", {
    focusable = true,

    measure = function(n, max_w, max_h)
        theme.set_font("medium")
        local h = theme.font_height() + 8
        if n._open then
            local items = n.options or {}
            local visible = math.min(#items, n.max_visible or 5)
            h = h + visible * (theme.font_height() + 4)
        end
        return max_w, h
    end,

    draw = function(n, d, x, y, w, h)
        local focused = n._focused
        local options = n.options or {}
        local selected = n.value or 1
        theme.set_font("medium")
        local fh = theme.font_height()
        local row_h = fh + 8

        -- Header
        local bg = theme.color("SURFACE")
        local border = focused and theme.color("ACCENT") or theme.color("BORDER")
        d.fill_round_rect(x, y, w, row_h, 3, bg)
        d.draw_round_rect(x, y, w, row_h, 3, border)

        local label = (options[selected] or "")
        if type(label) == "table" then label = label.label or "" end
        d.draw_text(x + 4, y + 4, label, theme.color("TEXT"))

        -- Arrow
        local arrow = n._open and "^" or "v"
        d.draw_text(x + w - 12, y + 4, arrow, theme.color("TEXT_MUTED"))

        -- Expanded list
        if n._open then
            local ly = y + row_h
            local visible = math.min(#options, n.max_visible or 5)
            local item_h = fh + 4
            local cursor = n._cursor or selected
            local scroll = n._scroll or 0

            d.fill_rect(x, ly, w, visible * item_h, theme.color("SURFACE"))
            d.draw_rect(x, ly, w, visible * item_h, theme.color("BORDER"))

            for i = 1, visible do
                local idx = i + scroll
                if idx > #options then break end
                local opt = options[idx]
                local lbl = type(opt) == "table" and opt.label or tostring(opt)
                local iy = ly + (i - 1) * item_h

                if idx == cursor then
                    d.fill_rect(x + 1, iy, w - 2, item_h, theme.color("SELECTION"))
                end
                d.draw_text(x + 4, iy + 2, lbl, theme.color("TEXT"))
            end
        end
    end,

    on_activate = function(n, key)
        if n._open then
            -- Confirm selection
            n.value = n._cursor or n.value or 1
            n._open = false
            if n.on_change then n.on_change(n.value) end
        else
            n._open = true
            n._cursor = n.value or 1
            n._scroll = 0
        end
        return "handled"
    end,

    on_key = function(n, key)
        if not n._open then return nil end
        local options = n.options or {}
        local cursor = n._cursor or 1
        local max_visible = n.max_visible or 5
        local scroll = n._scroll or 0

        if key.special == "UP" then
            if cursor > 1 then
                n._cursor = cursor - 1
                if n._cursor <= scroll then
                    n._scroll = math.max(0, scroll - 1)
                end
            end
            return "handled"
        elseif key.special == "DOWN" then
            if cursor < #options then
                n._cursor = cursor + 1
                if n._cursor > scroll + max_visible then
                    n._scroll = scroll + 1
                end
            end
            return "handled"
        elseif key.special == "ESCAPE" then
            n._open = false
            return "handled"
        end
        return nil
    end,
})

-- ---------------------------------------------------------------------------
-- ListItem: a selectable row for use inside scrollable lists
-- ---------------------------------------------------------------------------

node.register("list_item", {
    focusable = true,

    measure = function(n, max_w, max_h)
        theme.set_font("medium")
        local fh = theme.font_height()
        -- Compact: title only, minimal padding (about half the default height).
        if n.compact then
            return max_w, fh + 4
        end
        local h = fh + 8  -- single line with padding
        if n.subtitle then
            theme.set_font("small")
            h = h + theme.font_height() + 2
        end
        return max_w, h
    end,

    draw = function(n, d, x, y, w, h)
        local focused = n._focused
        local disabled = n.disabled
        local compact = n.compact

        -- Selection highlight (skip for disabled items)
        if focused and not disabled then
            d.fill_rect(x, y, w, h, theme.color("SELECTION"))
        end

        -- Color scheme: disabled items use muted colors
        local title_color, sub_color, icon_color
        if disabled then
            title_color = theme.color("TEXT_MUTED")
            sub_color = theme.color("TEXT_MUTED")
            icon_color = theme.color("TEXT_MUTED")
        elseif focused then
            title_color = theme.color("TEXT")
            sub_color = theme.color("TEXT_SEC")
            icon_color = theme.color("TEXT")
        else
            title_color = theme.color("TEXT")
            sub_color = theme.color("TEXT_SEC")
            icon_color = theme.color("TEXT_SEC")
        end

        -- Icon (optional PNG with sm/lg variants). Skipped in compact mode.
        local icon_space = 0
        if not compact and n.icon and n.icon.sm then
            local icon_w = 16
            local icon_x = x + 6
            local icon_y = y + math.floor((h - icon_w) / 2)
            d.draw_png(icon_x, icon_y, n.icon.sm)
            icon_space = icon_w + 10
        end

        local tx = x + 4 + icon_space
        local right_margin = 4

        -- Title
        theme.set_font("medium")
        local fh = theme.font_height()
        local ty = compact and (y + 2) or (y + 4)
        local title = n.title or ""
        local avail = w - 8 - right_margin - icon_space
        if n.trailing then
            theme.set_font("small")
            avail = avail - theme.text_width(n.trailing) - 4
            theme.set_font("medium")
        end
        if theme.text_width(title) > avail then
            title = text_util.truncate(title, avail)
        end
        d.draw_text(tx, ty, title, title_color)

        -- Trailing text (right-aligned)
        if n.trailing then
            theme.set_font("small")
            local tw = theme.text_width(n.trailing)
            d.draw_text(x + w - tw - right_margin, ty + 2, n.trailing, theme.color("TEXT_MUTED"))
        end

        -- Subtitle (suppressed in compact mode)
        if n.subtitle and not compact then
            theme.set_font("small")
            local sub = n.subtitle
            local sub_avail = w - 8 - icon_space
            if theme.text_width(sub) > sub_avail then
                sub = text_util.truncate(sub, sub_avail)
            end
            d.draw_text(tx, ty + fh + 2, sub, sub_color)
        end

        -- Bottom border
        d.draw_hline(x, y + h - 1, w, theme.color("BORDER"))
    end,

    on_activate = function(n, key)
        if n.disabled then return "handled" end
        if n.on_press then n.on_press() end
        return "handled"
    end,
})

-- ---------------------------------------------------------------------------
-- ProgressBar: horizontal progress indicator
-- ---------------------------------------------------------------------------

node.register("progress", {
    measure = function(n, max_w, max_h)
        return max_w, n.height or 8
    end,

    draw = function(n, d, x, y, w, h)
        local pct = math.max(0, math.min(1, n.value or 0))
        local bg = theme.color(n.bg_color or "SURFACE_ALT")
        local fg = theme.color(n.fg_color or "ACCENT")
        d.fill_round_rect(x, y, w, h, 3, bg)
        local fill_w = math.floor(w * pct)
        if fill_w > 0 then
            d.fill_round_rect(x, y, fill_w, h, 3, fg)
        end
    end,
})

-- ---------------------------------------------------------------------------
-- Slider: horizontal value slider with LEFT/RIGHT control
-- ---------------------------------------------------------------------------

node.register("slider", {
    focusable = true,

    measure = function(n, max_w, max_h)
        theme.set_font("small")
        local label_w = 0
        if n.label then
            theme.set_font("medium")
            label_w = theme.text_width(n.label) + 8
        end
        -- Value text width (e.g. "255")
        theme.set_font("small")
        local val_w = theme.text_width("255") + 8
        local h = math.max(theme.font_height() + 8, 20)
        return max_w, h
    end,

    draw = function(n, d, x, y, w, h)
        local focused = n._focused
        local min_val = n.min or 0
        local max_val = n.max or 255
        local value = math.max(min_val, math.min(max_val, n.value or min_val))
        local pct = (value - min_val) / math.max(1, max_val - min_val)

        -- Label on the left
        local track_x = x
        if n.label then
            theme.set_font("medium")
            local label_color = focused and theme.color("ACCENT") or theme.color("TEXT")
            d.draw_text(x + 2, y + math.floor((h - theme.font_height()) / 2), n.label, label_color)
            track_x = x + theme.text_width(n.label) + 10
        end

        -- Value text on the right
        theme.set_font("small")
        local val_str = tostring(math.floor(value))
        local val_w = theme.text_width(val_str)
        local val_x = x + w - val_w - 2
        local val_y = y + math.floor((h - theme.font_height()) / 2)
        d.draw_text(val_x, val_y, val_str, theme.color("TEXT_SEC"))

        -- Track
        local track_r = x + w - val_w - 10
        local track_w = track_r - track_x
        if track_w < 20 then return end
        local track_h = 6
        local track_y = y + math.floor((h - track_h) / 2)
        local track_bg = theme.color("SURFACE_ALT")
        local track_fg = focused and theme.color("ACCENT") or theme.color("ACCENT_DIM")

        d.fill_round_rect(track_x, track_y, track_w, track_h, 3, track_bg)
        local fill_w = math.floor(track_w * pct)
        if fill_w > 0 then
            d.fill_round_rect(track_x, track_y, fill_w, track_h, 3, track_fg)
        end

        -- Thumb
        local thumb_r = 5
        local thumb_x = track_x + fill_w
        local thumb_y = y + math.floor(h / 2)
        local thumb_color = focused and theme.color("TEXT") or theme.color("TEXT_SEC")
        d.fill_circle(thumb_x, thumb_y, thumb_r, thumb_color)
        if focused then
            d.draw_circle(thumb_x, thumb_y, thumb_r + 1, theme.color("ACCENT"))
        end
    end,

    on_key = function(n, key)
        if not n._focused then return nil end
        local min_val = n.min or 0
        local max_val = n.max or 255
        local step = n.step or math.max(1, math.floor((max_val - min_val) / 20))
        local value = n.value or min_val

        if key.special == "RIGHT" then
            n.value = math.min(max_val, value + step)
            if n.on_change then n.on_change(n.value) end
            return "handled"
        elseif key.special == "LEFT" then
            n.value = math.max(min_val, value - step)
            if n.on_change then n.on_change(n.value) end
            return "handled"
        end
        return nil
    end,
})

-- ---------------------------------------------------------------------------
-- StatusBar: battery + radio + time + node ID
-- ---------------------------------------------------------------------------

node.register("status_bar", {
    measure = function(n, max_w, max_h)
        return max_w, theme.STATUS_H
    end,

    draw = function(n, d, x, y, w, h)
        d.fill_rect(x, y, w, h, theme.color("STATUS_BG"))
        theme.set_font("small")
        local fh = theme.font_height()
        local ty = y + math.floor((h - fh) / 2)

        -- Node ID (left)
        if n.node_id then
            d.draw_text(x + 4, ty, n.node_id, theme.color("TEXT_SEC"))
        end

        -- Time (right)
        if n.time then
            local tw = theme.text_width(n.time)
            d.draw_text(x + w - tw - 4, ty, n.time, theme.color("TEXT_SEC"))
        end

        -- Battery icon (right of center)
        if n.battery then
            local bx = x + w - 50
            d.draw_battery(bx, y + 4, n.battery, theme.color("TEXT_SEC"))
        end

        -- Radio indicator
        if n.radio_ok ~= nil then
            local rx = x + 60
            if n.radio_ok then
                d.draw_signal(rx, y + 4, n.signal_bars or 0, theme.color("SUCCESS"))
            else
                theme.set_font("small")
                d.draw_text(rx, ty, "!RF", theme.color("ERROR"))
            end
        end

        -- Bottom border
        d.draw_hline(x, y + h - 1, w, theme.color("BORDER"))
    end,
})

-- ---------------------------------------------------------------------------
-- TitleBar: screen title with optional back hint
-- ---------------------------------------------------------------------------

node.register("title_bar", {
    measure = function(n, max_w, max_h)
        return max_w, theme.TITLE_H
    end,

    draw = function(n, d, x, y, w, h)
        d.fill_rect(x, y, w, h, theme.color("SURFACE"))
        theme.set_font("medium")
        local fh = theme.font_height()
        local ty = y + math.floor((h - fh) / 2)

        -- Title centered
        local title = n.title or ""
        local tw = theme.text_width(title)
        d.draw_text(x + math.floor((w - tw) / 2), ty, title, theme.color("TEXT"))

        -- Back hint (left)
        if n.back then
            theme.set_font("small")
            d.draw_text(x + 4, ty + 1, "q Back", theme.color("TEXT_MUTED"))
        end

        -- Bottom border
        d.draw_hline(x, y + h - 1, w, theme.color("BORDER"))
    end,
})

-- ---------------------------------------------------------------------------
-- Spinner: animated loading indicator (rotating dots)
-- ---------------------------------------------------------------------------

node.register("spinner", {
    measure = function(n, max_w, max_h)
        local size = n.size or 12
        return size, size
    end,

    draw = function(n, d, x, y, w, h)
        local color = theme.color(n.color or "ACCENT")
        local dim_color = theme.color(n.dim_color or "SURFACE_ALT")
        local num_dots = n.dots or 4
        local r = math.floor(math.min(w, h) / 2) - 1
        local dot_r = math.max(1, math.floor(r / 3))
        local cx = x + math.floor(w / 2)
        local cy = y + math.floor(h / 2)
        local speed = n.speed or 150  -- ms per step
        local phase = math.floor(ez.system.millis() / speed) % num_dots

        for i = 0, num_dots - 1 do
            local angle = (i / num_dots) * 2 * math.pi - math.pi / 2
            local dx = cx + math.floor(r * math.cos(angle))
            local dy = cy + math.floor(r * math.sin(angle))
            local c = (i == phase) and color or dim_color
            d.fill_circle(dx, dy, dot_r, c)
        end

        -- Mark screen dirty so the animation keeps running
        n._animating = true
    end,
})

-- ---------------------------------------------------------------------------
-- Constructor helpers (shorthand for creating node tables)
-- ---------------------------------------------------------------------------

function W.text(value, props)
    props = props or {}
    props.type = "text"
    props.value = value
    return props
end

function W.button(label, props)
    props = props or {}
    props.type = "button"
    props.label = label
    return props
end

function W.toggle(label, value, props)
    props = props or {}
    props.type = "toggle"
    props.label = label
    props.value = value
    return props
end

function W.text_input(props)
    props = props or {}
    props.type = "text_input"
    if not props.value then props.value = "" end
    return props
end

function W.dropdown(options, props)
    props = props or {}
    props.type = "dropdown"
    props.options = options
    if not props.value then props.value = 1 end
    return props
end

function W.list_item(props)
    props = props or {}
    props.type = "list_item"
    return props
end

function W.progress(value, props)
    props = props or {}
    props.type = "progress"
    props.value = value
    return props
end

function W.status_bar(props)
    props = props or {}
    props.type = "status_bar"
    return props
end

function W.title_bar(title, props)
    props = props or {}
    props.type = "title_bar"
    props.title = title
    return props
end

function W.spinner(props)
    props = props or {}
    props.type = "spinner"
    return props
end

function W.slider(props)
    props = props or {}
    props.type = "slider"
    return props
end

return W
