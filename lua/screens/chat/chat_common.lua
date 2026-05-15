-- Shared chat bubble node type for channel and DM screens
-- Registers the "chat_bubble" node type with left/right alignment.
-- Bubbles are focusable for keyboard navigation and context menus.
--
-- Share-card mode: when the screen attaches a `share` table to the
-- bubble node, the bubble switches to a wider, card-style layout that
-- previews what tapping it would do (Add contact / Join channel) and
-- shows a state line ("Tap to add" / "Already added" / "Cannot open").
-- The screen owns the parse + decode work because invite tokens need
-- the sender pubkey and a per-screen cache to avoid re-running X25519
-- on every rebuild; chat_common just renders what it's given.

local theme = require("ezui.theme")
local node_mod = require("ezui.node")
local text_mod = require("ezui.text")

local chat = {}

-- Constants
local BUBBLE_MAX_PCT = 0.78   -- bubble max width as fraction of container
local SHARE_MAX_PCT  = 0.92   -- share cards take more width than text bubbles
local PAD_X = 5
local PAD_Y = 3
local RADIUS = 4
local BUBBLE_GAP = 2

-- Measure / draw helpers for share-card bubbles. Kept in their own
-- pair so the regular chat-bubble path stays untouched and easy to
-- read; the dispatcher in measure/draw chooses based on n.share.
local function measure_share(n, max_w)
    local share = n.share
    local msg = n.msg or {}
    local card_max = math.floor(max_w * SHARE_MAX_PCT)
    local inner_w = card_max - PAD_X * 2

    -- Kind label (tiny), main title (small), action hint (tiny). Title
    -- can wrap if the name is unusually long; the others are
    -- single-line. Received cards also get an RSSI footer line in the
    -- tiny font when msg.rssi is set, matching the plain-text bubble.
    theme.set_font("tiny_aa")
    local meta_h = theme.font_height() + 1

    theme.set_font("small_aa")
    local title_lines = text_mod.wrap(share.title or "", inner_w)
    n._share_title_lines = title_lines
    local title_h = theme.font_height() * #title_lines

    theme.set_font("tiny_aa")
    local action_h = theme.font_height() + 1
    local rssi_h = 0
    if (not msg.is_self) and msg.rssi then
        rssi_h = theme.font_height() + 1
    end

    n._card_w = card_max
    n._title_h = title_h
    n._meta_h = meta_h
    n._action_h = action_h
    n._rssi_h = rssi_h
    n._line_h = theme.font_height()  -- used for tiny-font lines

    local total_h = meta_h + title_h + action_h + rssi_h + PAD_Y * 2 + BUBBLE_GAP
    return max_w, total_h
end

local function draw_share(n, d, x, y, w, h)
    local share = n.share
    local msg = n.msg or {}
    local focused = n._focused

    local card_w = n._card_w or math.floor(w * SHARE_MAX_PCT)
    local title_h = n._title_h or 12
    local meta_h = n._meta_h or 10
    local action_h = n._action_h or 10
    local rssi_h = n._rssi_h or 0
    local card_h = meta_h + title_h + action_h + rssi_h + PAD_Y * 2

    local cx = msg.is_self and (x + w - card_w - 2) or (x + 2)
    local cy = y

    -- Background: filled with ACCENT-tinted SURFACE so the card stands
    -- out from regular chat. Outline highlights when focused.
    local bg = focused and theme.color("SELECTION") or theme.color("SURFACE_ALT")
    local border = focused and theme.color("ACCENT") or theme.color("BORDER")
    d.fill_round_rect(cx, cy, card_w, card_h, RADIUS, bg)
    d.draw_round_rect(cx, cy, card_w, card_h, RADIUS, border)

    if focused then
        -- Same focus bar as regular bubbles, on the matching edge
        local bar = theme.color("ACCENT")
        if msg.is_self then
            d.fill_rect(cx + card_w - 2, cy + 2, 2, card_h - 4, bar)
        else
            d.fill_rect(cx, cy + 2, 2, card_h - 4, bar)
        end
    end

    local ty = cy + PAD_Y

    -- Kind label, e.g. "CONTACT CARD" / "CHANNEL INVITE"
    theme.set_font("tiny_aa")
    d.draw_text(cx + PAD_X, ty, share.kind_label or "SHARE", theme.color("ACCENT"))
    ty = ty + meta_h

    -- Title (the contact name or channel name)
    theme.set_font("small_aa")
    for _, line in ipairs(n._share_title_lines or { share.title or "" }) do
        d.draw_text(cx + PAD_X, ty, line, theme.color("TEXT"))
        ty = ty + n._line_h
    end

    -- Action hint, color-coded: muted for done/disabled states, accent
    -- for the actionable "Tap to ..." paths.
    theme.set_font("tiny_aa")
    local hint_color = share.disabled and theme.color("TEXT_MUTED") or theme.color("ACCENT")
    d.draw_text(cx + PAD_X, ty, share.action_hint or "Tap for details", hint_color)
    ty = ty + action_h

    -- RSSI footer: received cards mirror the plain-text bubble's
    -- meta line so link quality is visible regardless of payload type.
    if rssi_h > 0 and msg.rssi then
        local rssi_str = string.format("%ddBm", math.floor(msg.rssi))
        d.draw_text(cx + PAD_X, ty, rssi_str, theme.color("TEXT_MUTED"))
    end
end

if not node_mod.handler("chat_bubble") then
    node_mod.register("chat_bubble", {
        focusable = true,

        measure = function(n, max_w, max_h)
            local msg = n.msg
            if not msg then return max_w, 16 end

            if n.share then
                return measure_share(n, max_w)
            end

            local bubble_max = math.floor(max_w * BUBBLE_MAX_PCT)
            local inner_w = bubble_max - PAD_X * 2

            -- Sender name line (only for received messages)
            theme.set_font("tiny_aa")
            local name_h = 0
            if not msg.is_self then
                name_h = theme.font_height() + 1
            end

            -- Message text wrapped in small font
            theme.set_font("small_aa")
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
                theme.set_font("tiny_aa")
                local name_w = theme.text_width(msg.sender_name or "")
                if msg.count and msg.count > 1 then
                    name_w = name_w + theme.text_width(" (x" .. msg.count .. ")")
                end
                if name_w > max_line_w then max_line_w = name_w end
            end

            -- Meta line (timestamp/rssi/status) in tiny font
            theme.set_font("tiny_aa")
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

            if n.share then
                return draw_share(n, d, x, y, w, h)
            end

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
                theme.set_font("tiny_aa")
                local name_text = msg.sender_name or "?"
                if msg.count and msg.count > 1 then
                    name_text = name_text .. " (x" .. msg.count .. ")"
                end
                d.draw_text(bx + PAD_X, cy, name_text, theme.color("INFO"))
                cy = cy + name_h
            end

            -- Message text lines
            theme.set_font("small_aa")
            for _, line in ipairs(lines) do
                d.draw_text(bx + PAD_X, cy, line, theme.color("TEXT"))
                cy = cy + line_h
            end

            -- Meta line: RSSI for received, empty for sent (status shown via dot)
            theme.set_font("tiny_aa")
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
                elseif status == "read" then
                    -- Receiver has opened the conversation and the
                    -- read-receipt URI came back. Paint with the
                    -- accent colour so it stands apart from the
                    -- plain "delivered" dot. The footer rendering
                    -- below adds a second ring to make the
                    -- difference unmistakable on either palette.
                    dot_color = theme.color("ACCENT")
                elseif status == "unconfirmed" then
                    dot_color = theme.color("WARNING")
                elseif status == "failed" then
                    dot_color = theme.color("ERROR")
                else
                    -- "sent" (no ACK expected): muted
                    dot_color = theme.color("TEXT_MUTED")
                end

                d.fill_circle(dot_x, dot_y, dot_r, dot_color)
                if status == "read" then
                    -- Outer ring so the read state reads as two
                    -- concentric marks at a glance (the "double check"
                    -- pattern the issue suggests, adapted for a dot
                    -- that's only 3px wide).
                    d.draw_circle(dot_x, dot_y, dot_r + 2, dot_color)
                end
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
