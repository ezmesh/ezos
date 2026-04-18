-- Shared chat bubble node type for channel and DM screens
-- Registers the "chat_bubble" node type with left/right alignment.
-- Bubbles are focusable for keyboard navigation and context menus.

local theme = require("ezui.theme")
local node_mod = require("ezui.node")
local text_mod = require("ezui.text")

local chat = {}

-- Constants
local BUBBLE_MAX_PCT = 0.78   -- bubble max width as fraction of container
local PAD_X = 5
local PAD_Y = 3
local RADIUS = 4
local BUBBLE_GAP = 2

if not node_mod.handler("chat_bubble") then
    node_mod.register("chat_bubble", {
        focusable = true,

        measure = function(n, max_w, max_h)
            local msg = n.msg
            if not msg then return max_w, 16 end

            local bubble_max = math.floor(max_w * BUBBLE_MAX_PCT)
            local inner_w = bubble_max - PAD_X * 2

            -- Sender name line (only for received messages)
            theme.set_font("tiny")
            local name_h = 0
            if not msg.is_self then
                name_h = theme.font_height() + 1
            end

            -- Message text wrapped in small font
            theme.set_font("small")
            local lines = text_mod.wrap(msg.text or "", inner_w)
            n._lines = lines
            local line_h = theme.font_height()
            local text_h = line_h * #lines

            -- Compute actual bubble width from longest line
            local max_line_w = 0
            for _, line in ipairs(lines) do
                local lw = theme.text_width(line)
                if lw > max_line_w then max_line_w = lw end
            end

            -- Include sender name width in bubble width calculation
            if not msg.is_self then
                theme.set_font("tiny")
                local name_w = theme.text_width(msg.sender_name or "")
                if msg.count and msg.count > 1 then
                    name_w = name_w + theme.text_width(" (x" .. msg.count .. ")")
                end
                if name_w > max_line_w then max_line_w = name_w end
            end

            -- Meta line (timestamp/rssi/status) in tiny font
            theme.set_font("tiny")
            local meta_h = theme.font_height() + 1

            local bubble_w = math.min(max_line_w + PAD_X * 2, bubble_max)
            n._bubble_w = bubble_w
            n._text_h = text_h
            n._name_h = name_h
            n._meta_h = meta_h
            n._line_h = line_h

            local total_h = name_h + text_h + meta_h + PAD_Y * 2 + BUBBLE_GAP
            return max_w, total_h
        end,

        draw = function(n, d, x, y, w, h)
            local msg = n.msg
            if not msg then return end

            local focused = n._focused
            local bubble_w = n._bubble_w or 100
            local name_h = n._name_h or 0
            local text_h = n._text_h or 12
            local meta_h = n._meta_h or 10
            local line_h = n._line_h or 12
            local lines = n._lines or { msg.text or "" }

            local bubble_h = name_h + text_h + meta_h + PAD_Y * 2
            local bx, by

            if msg.is_self then
                bx = x + w - bubble_w - 2
            else
                bx = x + 2
            end
            by = y

            -- Bubble background
            if msg.is_self then
                -- Sent: outline style
                local border = focused and theme.color("ACCENT") or theme.color("BORDER")
                d.fill_round_rect(bx, by, bubble_w, bubble_h, RADIUS, theme.color("BG"))
                d.draw_round_rect(bx, by, bubble_w, bubble_h, RADIUS, border)
            else
                -- Received: filled
                local bg = focused and theme.color("SELECTION") or theme.color("SURFACE")
                d.fill_round_rect(bx, by, bubble_w, bubble_h, RADIUS, bg)
            end

            -- Focus indicator: thin vertical bar on the edge of the bubble
            if focused then
                local bar_color = theme.color("ACCENT")
                if msg.is_self then
                    d.fill_rect(bx + bubble_w - 2, by + 2, 2, bubble_h - 4, bar_color)
                else
                    d.fill_rect(bx, by + 2, 2, bubble_h - 4, bar_color)
                end
            end

            local cy = by + PAD_Y

            -- Sender name (received only)
            if not msg.is_self then
                theme.set_font("tiny")
                local name_text = msg.sender_name or "?"
                if msg.count and msg.count > 1 then
                    name_text = name_text .. " (x" .. msg.count .. ")"
                end
                d.draw_text(bx + PAD_X, cy, name_text, theme.color("INFO"))
                cy = cy + name_h
            end

            -- Message text lines
            theme.set_font("small")
            for _, line in ipairs(lines) do
                d.draw_text(bx + PAD_X, cy, line, theme.color("TEXT"))
                cy = cy + line_h
            end

            -- Meta line: RSSI for received, empty for sent (status shown via dot)
            theme.set_font("tiny")
            if not msg.is_self then
                if msg.rssi then
                    local rssi_str = string.format("%ddBm", math.floor(msg.rssi))
                    d.draw_text(bx + PAD_X, cy + 1, rssi_str, theme.color("TEXT_MUTED"))
                end
            end

            -- Status light: small dot at bottom-right of sent bubbles
            if msg.is_self then
                local status = msg.status or "sent"
                local dot_r = 3
                local dot_x = bx + bubble_w - PAD_X - dot_r
                local dot_y = by + bubble_h - PAD_Y - dot_r
                local dot_color

                if status == "pending" then
                    -- Pulsing amber: waiting for ACK
                    local pulse = math.floor(ez.system.millis() / 300) % 2
                    dot_color = pulse == 0 and theme.color("WARNING") or theme.color("SURFACE_ALT")
                    n._animating = true
                elseif status == "delivered" then
                    dot_color = theme.color("SUCCESS")
                elseif status == "unconfirmed" then
                    dot_color = theme.color("WARNING")
                elseif status == "failed" then
                    dot_color = theme.color("ERROR")
                else
                    -- "sent" (no ACK expected): muted
                    dot_color = theme.color("TEXT_MUTED")
                end

                d.fill_circle(dot_x, dot_y, dot_r, dot_color)
            end
        end,

        on_activate = function(n, key)
            if n.on_press then n.on_press() end
            return "handled"
        end,

        on_key = function(n, key)
            -- Let UP/DOWN pass through to focus system for navigation
            return nil
        end,
    })
end

return chat
