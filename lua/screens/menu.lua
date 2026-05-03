-- Main menu screen (accessible from desktop via Tab or More icon)
--
-- Top-level layout: a horizontal tab strip below the title bar (same
-- visual style as the Messages Private/Channels tabs -- SURFACE
-- background, ACCENT underline on the active tab, BORDER hairline at
-- the bottom -- but with horizontal scroll so we can fit more than
-- two labels), and the items of the active tab listed vertically
-- below it.
-- Navigation:
--   LEFT / RIGHT  : switch tab (also wraps around the ends)
--   UP   / DOWN   : move focus through the items of the current tab
--   ENTER         : open the focused item
--   ESC / BKSP    : back to desktop
-- The current tab + focus + scroll are persisted in the transient
-- store so re-opening the menu lands you back where you were, and so
-- does coming back from a sub-screen (on_leave/on_exit save).

local ui        = require("ezui")
local icons     = require("ezui.icons")
local theme     = require("ezui.theme")
local node_mod  = require("ezui.node")
local transient = require("ezui.transient")
local focus_mod = require("ezui.focus")

local Menu = { title = "Menu" }

-- Transient key for "last place the user was at in the menu" — the
-- focused item, the scroll offset, and the active tab.
local MENU_STATE_KEY = "menu"

-- Categories drive both the tab strip and the item list. Keep the
-- definitions data-only here so adding/moving an entry is one line.
-- Each entry has a `mod` (Lua module path) or a `screen` (LittleFS
-- path), the same shape _make_item already understood.
local CATEGORIES = {
    {
        id    = "comm",
        label = "Communication",
        title = "Communication",
        entries = {
            { title = "Messages", subtitle = "Private & channels",
              icon = icons.mail,  screen = "$screens/chat/messages.lua" },
            { title = "Contacts", subtitle = "Known nodes",
              icon = icons.users, mod = "screens.chat.contacts" },
        },
    },
    {
        id    = "apps",
        label = "Apps",
        title = "Apps",
        -- Productivity-style apps with their own document model
        -- (canvas, text buffer, file tree, map archive). Files and
        -- Map were previously under Tools but conceptually belong
        -- here -- they're persistent-state apps the user spends time
        -- inside, not one-shot diagnostics.
        entries = {
            { title = "Paint", subtitle = "Draw with palette, brush, eraser, fill",
              icon = icons.paintbrush, mod = "screens.apps.paint" },
            { title = "Editor", subtitle = "Edit text & Lua files on flash / SD",
              icon = icons.square_pen, mod = "screens.apps.editor" },
            { title = "Files", subtitle = "Flash & SD browser",
              icon = icons.folder, mod = "screens.tools.file_manager" },
            { title = "Map", subtitle = "Offline maps",
              icon = icons.map, mod = "screens.tools.map_loader" },
        },
    },
    {
        id    = "tools",
        label = "Tools",
        title = "Tools",
        entries = {
            { title = "Notifications", subtitle = "Recent system events",
              icon = icons.bell, mod = "screens.tools.notifications" },
            { title = "Claude", subtitle = "Chat with the dev host",
              icon = icons.bot, mod = "screens.tools.claude" },
            { title = "Help", subtitle = "On-device manual + API",
              icon = icons.help, mod = "screens.tools.help" },
            { title = "Terminal", subtitle = "Shell: cd, ls, run",
              icon = icons.terminal, mod = "screens.tools.terminal" },
        },
    },
    {
        id    = "games",
        label = "Games",
        title = "Games",
        entries = {
            { title = "Solitaire", subtitle = "Klondike card game",
              icon = icons.spade, mod = "screens.games.solitaire" },
            { title = "Minesweeper", subtitle = "Classic puzzle",
              icon = icons.bomb, mod = "screens.games.minesweeper" },
            { title = "Sudoku", subtitle = "Number puzzle",
              icon = icons.grid, mod = "screens.games.sudoku" },
            { title = "Wasteland", subtitle = "Outdoor zombie 3D shooter",
              icon = icons.skull, mod = "screens.games.wasteland" },
            { title = "Breakout", subtitle = "Paddle bricks across 5 levels",
              icon = icons.blocks, mod = "screens.games.breakout" },
            { title = "Tetris", subtitle = "Top-5 high scores (local)",
              icon = icons.blocks, mod = "screens.games.tetris" },
            { title = "Pong (2P WiFi)", subtitle = "Head-to-head over SoftAP + UDP",
              icon = icons.circle_dot, mod = "screens.games.pong" },
            { title = "Starshot", subtitle = "Space shooter, guns+items (2P)",
              icon = icons.rocket, mod = "screens.games.shooter" },
            { title = "Platformer", subtitle = "12 levels, 4 environments (2P WiFi)",
              icon = icons.gamepad, mod = "screens.games.platformer" },
        },
    },
    {
        id    = "diag",
        label = "Diagnostics",
        title = "Diagnostics",
        entries = {
            { title = "Signal Test", subtitle = "RSSI pingpong vs time",
              icon = icons.signal, mod = "screens.tools.signal_test" },
            { title = "WiFi Test", subtitle = "SoftAP host + join UDP RTT",
              icon = icons.wifi, mod = "screens.tools.wifi_test" },
            { title = "HTTP Test", subtitle = "Host a status page on :80",
              icon = icons.globe, mod = "screens.tools.http_test" },
            { title = "Channel Sniffer", subtitle = "Live GRP_TXT channel hashes seen on the air",
              icon = icons.radio, mod = "screens.tools.channel_sniffer" },
            { title = "Touch Test", subtitle = "GT911 multi-touch coordinates + trails",
              icon = icons.circle_dot, mod = "screens.tools.touch_test" },
            { title = "Pixel Fix", subtitle = "Clear screen ghosting",
              icon = icons.monitor, mod = "screens.tools.pixel_fix" },
        },
    },
    {
        id    = "system",
        label = "System",
        title = "System",
        -- Settings used to be a separate sub-page (screens/settings/
        -- settings.lua); we flattened those rows directly into this
        -- tab so users only need one tap to reach Display / WiFi /
        -- etc. The dev-flavoured operations (Dev OTA, Claude Bot,
        -- Rollback) sit on the Dev tab below; this tab is just the
        -- end-user "settings" view plus Repeat-onboarding / About.
        entries = {
            { title = "Display", subtitle = "Brightness, theme, accent",
              icon = icons.palette, mod = "screens.settings.display_settings" },
            { title = "WiFi", subtitle = "Scan, connect, save credentials",
              icon = icons.wifi, mod = "screens.settings.wifi_settings" },
            { title = "Wallpaper", subtitle = "Rotate, tile, auto-pan",
              icon = icons.wallpaper, mod = "screens.settings.wallpaper_settings" },
            { title = "Keyboard", subtitle = "Repeat, trackball",
              icon = icons.keyboard, mod = "screens.settings.keyboard_settings" },
            { title = "GPS", subtitle = "Power, clock sync",
              icon = icons.navigation, mod = "screens.settings.gps_settings" },
            { title = "Time", subtitle = "Timezone, 12 / 24h format, NTP",
              icon = icons.clock, mod = "screens.settings.time_settings" },
            { title = "Radio", subtitle = "Mesh advert, announce cadence",
              icon = icons.radio_tower, mod = "screens.settings.radio_settings" },
            { title = "Sound", subtitle = "UI feedback, volume",
              icon = icons.volume, mod = "screens.settings.sound_settings" },
            { title = "Repeat onboarding", subtitle = "Walk through the first-run wizard again",
              icon = icons.rotate_cw, action = function()
                  require("screens.onboarding").start()
              end },
            { title = "About", subtitle = "Credits, attributions, version",
              icon = icons.info, mod = "screens.about" },
        },
    },
    {
        id    = "dev",
        label = "Dev",
        title = "Developer",
        entries = {
            { title = "Dev OTA", subtitle = "Push firmware over WiFi from a host",
              icon = icons.cloud_upload, mod = "screens.settings.dev_ota" },
            { title = "Claude Bot", subtitle = "Chat host URL + bearer token",
              icon = icons.bot, mod = "screens.settings.claude_bot" },
            { title = "Rollback firmware", subtitle = "Revert to the previous OTA slot and reboot",
              icon = icons.rotate_ccw, action = function()
                  -- Pulled inline from the old system_settings.lua so
                  -- removing that submenu didn't lose the confirm
                  -- dialog. Same flow: push a small modal asking the
                  -- user to confirm, run rollback_and_reboot on OK,
                  -- and surface a "no other slot" failure if the API
                  -- returns rather than rebooting.
                  local screen_mod = require("ezui.screen")
                  local function confirm(title, body, ok_label, on_ok)
                      local Confirm = { title = title }
                      function Confirm:build(_s)
                          return ui.vbox({ gap = 0, bg = "BG" }, {
                              ui.title_bar(title, { back = true }),
                              ui.padding({ 14, 14, 8, 14 },
                                  ui.text_widget(body,
                                      { font = "small_aa", color = "TEXT", wrap = true })),
                              ui.padding({ 6, 14, 4, 14 },
                                  ui.button(ok_label, { on_press = function()
                                      screen_mod.pop()
                                      on_ok()
                                  end })),
                              ui.padding({ 4, 14, 4, 14 },
                                  ui.button("Cancel", { on_press = function()
                                      screen_mod.pop()
                                  end })),
                          })
                      end
                      function Confirm:handle_key(k)
                          if k.special == "BACKSPACE" or k.special == "ESCAPE" then
                              return "pop"
                          end
                          return nil
                      end
                      screen_mod.push(screen_mod.create(Confirm, {}))
                  end
                  local running = ez.ota and ez.ota.running_partition
                      and ez.ota.running_partition() or "?"
                  confirm("Rollback firmware",
                      "Marks the running image (" .. running .. ") bad and " ..
                      "reboots into the previous slot. Use this if the " ..
                      "current build is broken.",
                      "Rollback and reboot",
                      function()
                          if ez.ota and ez.ota.rollback_and_reboot then
                              ez.ota.rollback_and_reboot()
                              -- Returns only on failure.
                              confirm("Rollback failed",
                                  "No other valid firmware slot is available. " ..
                                  "Push a fresh image via Dev OTA first.",
                                  "OK", function() end)
                          end
                      end)
              end },
            { title = "Widget kitchen sink", subtitle = "Every widget on one screen",
              icon = icons.layers, mod = "screens.dev.kitchen_sink" },
            { title = "Prefs Editor", subtitle = "Browse, edit, reset, or add NVS prefs",
              icon = icons.sliders, mod = "screens.dev.prefs_editor" },
        },
    },
}

-- ---------------------------------------------------------------------------
-- Scrollable tab bar node
--
-- Modeled on the Messages screen's tab_bar (full-width SURFACE strip,
-- ACCENT underline on the active tab, BORDER hairline at the bottom)
-- but with two changes:
--   * tabs are sized to their label width plus padding, not split
--     equally, so longer labels stay readable;
--   * a horizontal scroll offset shifts the strip when the active tab
--     would otherwise sit off-screen. The offset is recomputed every
--     draw so a tab change always brings the new tab into view, and
--     it stays clamped to the natural [0 .. content_w - viewport_w]
--     range so we don't paint a gap at either end.
-- The node itself is non-focusable; the host screen handles LEFT /
-- RIGHT to advance the active index, then triggers a rebuild and the
-- node redraws with the new selection.
-- ---------------------------------------------------------------------------

local TAB_PAD_X      = 12   -- horizontal padding inside each tab
local TAB_GAP        = 0    -- gap between adjacent tabs (0 keeps the
                            -- underline strip continuous)
local TAB_BAR_FONT   = "medium_aa"
-- Strip height: 22 px feels right with the trackball, but on a
-- touch device the same strip is too narrow to hit reliably. Bump
-- to MIN_TARGET_H when the GT911 is up so a finger gets a row that
-- matches the rest of the touch-friendly UI.
local TAB_BAR_HEIGHT_KEYS  = 22
local TAB_BAR_HEIGHT_TOUCH = 32

if not node_mod.handler("scroll_tab_bar") then
    -- Compute per-tab pixel widths from the label list. Returns the
    -- accumulated array so a draw can find each tab's x-range with a
    -- single subtraction.
    local function compute_widths(tabs)
        theme.set_font(TAB_BAR_FONT)
        local widths = {}
        local total = 0
        for i, label in ipairs(tabs) do
            local lw = theme.text_width(label)
            local tw = lw + TAB_PAD_X * 2
            widths[i] = tw
            total = total + tw + (i < #tabs and TAB_GAP or 0)
        end
        return widths, total
    end

    node_mod.register("scroll_tab_bar", {
        measure = function(n, max_w, max_h)
            local touch_input = require("ezui.touch_input")
            local h = touch_input.touch_enabled()
                and TAB_BAR_HEIGHT_TOUCH
                or  TAB_BAR_HEIGHT_KEYS
            return max_w, h
        end,

        draw = function(n, d, x, y, w, h)
            local tabs   = n.tabs   or {}
            local active = n.active or 1
            if #tabs == 0 then return end

            local widths, total = compute_widths(tabs)
            local max_scroll = math.max(0, total - w)

            -- Auto-scroll-to-active: keep the active tab on screen
            -- when LEFT/RIGHT cycles past the viewport edge. We only
            -- run this when `n._scroll_dirty` is set (the field is
            -- set by the host screen on _set_tab() and after the
            -- first build). A user finger drag intentionally moves
            -- the strip away from the active tab, so this block must
            -- NOT run on every frame -- otherwise the next render
            -- would snap the scroll back and the drag would feel
            -- broken.
            local scroll = n._scroll or 0
            if n._scroll_dirty then
                local active_x = 0
                for i = 1, active - 1 do
                    active_x = active_x + widths[i] + TAB_GAP
                end
                local active_w = widths[active] or 0
                if active_x + active_w > scroll + w then
                    scroll = active_x + active_w - w
                end
                if active_x < scroll then
                    scroll = active_x
                end
                n._scroll_dirty = nil
            end
            -- Always re-clamp -- the user's drag handler may have
            -- pushed scroll past the new bounds if widths shrunk
            -- between rebuilds.
            if scroll < 0 then scroll = 0 end
            if scroll > max_scroll then scroll = max_scroll end
            n._scroll = scroll

            -- Backdrop: full-width SURFACE behind every tab so the
            -- inactive labels read as part of the same strip even when
            -- the active underline is the only colour accent.
            d.fill_rect(x, y, w, h, theme.color("SURFACE"))

            theme.set_font(TAB_BAR_FONT)
            local fh = theme.font_height()
            local cx = x - scroll
            for i, label in ipairs(tabs) do
                local tw = widths[i]
                -- Skip tabs entirely off-screen on either side; we
                -- still need to walk the index to keep cx aligned.
                local tab_right = cx + tw
                if tab_right > x and cx < x + w then
                    local lw = theme.text_width(label)
                    local lx = cx + math.floor((tw - lw) / 2)
                    local ly = y + math.floor((h - fh) / 2)
                    if i == active then
                        d.draw_text(lx, ly, label, theme.color("TEXT"))
                        d.fill_rect(cx + 4, y + h - 2, tw - 8, 2,
                            theme.color("ACCENT"))
                    else
                        d.draw_text(lx, ly, label, theme.color("TEXT_MUTED"))
                    end
                end
                cx = cx + tw + TAB_GAP
            end

            -- BORDER hairline at the bottom, drawn last so the active
            -- accent underline still reads above it.
            d.fill_rect(x, y + h - 1, w, 1, theme.color("BORDER"))

            -- Edge gradients to hint at scrollable content. Cheap
            -- single-pixel SURFACE_ALT seam on whichever side has more
            -- tabs hidden.
            if scroll > 0 then
                d.fill_rect(x, y, 1, h - 1, theme.color("BORDER"))
            end
            if scroll < max_scroll then
                d.fill_rect(x + w - 1, y, 1, h - 1, theme.color("BORDER"))
            end
        end,
    })
end

local function build_tab_strip(menu_self, active_idx)
    -- Persist the strip node on the screen instance so the touch
    -- handler attached at on_enter can read its drawn rect (_x/_y/
    -- _ah) and current scroll offset (_scroll). Without persistence
    -- every rebuild would orphan the previous node and the touch
    -- handler would point at stale geometry.
    if not menu_self._tab_strip_node then
        local labels = {}
        for i, c in ipairs(CATEGORIES) do labels[i] = c.label end
        menu_self._tab_strip_node = {
            type = "scroll_tab_bar",
            tabs = labels,
            -- First draw should auto-centre on whatever tab the
            -- transient store restored, even if no _set_tab call has
            -- happened in this open.
            _scroll_dirty = true,
        }
    end
    menu_self._tab_strip_node.active = active_idx
    return menu_self._tab_strip_node
end

function Menu:build(state)
    local items = {}
    items[#items + 1] = ui.title_bar("Menu", { back = true })

    local active_idx = state.tab_idx or 1
    if active_idx < 1 or active_idx > #CATEGORIES then active_idx = 1 end
    local active_cat = CATEGORIES[active_idx]

    items[#items + 1] = build_tab_strip(self, active_idx)

    -- The tab strip already labels the current category, so the
    -- old in-list section header would just repeat what's pinned a
    -- few pixels above. Skip it and let the first row sit flush
    -- against the tab bar's bottom border.
    local content_items = {}
    for _, entry in ipairs(active_cat.entries) do
        content_items[#content_items + 1] = self:_make_item(entry)
    end

    local content = ui.vbox({ gap = 0 }, content_items)
    items[#items + 1] = ui.scroll(
        { grow = 1, scroll_offset = state.scroll or 0 }, content)

    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

function Menu.initial_state()
    local saved = transient.load(MENU_STATE_KEY, {})
    return {
        scroll  = saved.scroll or 0,
        tab_idx = saved.tab_idx or 1,
    }
end

-- Capture the focused item, scroll offset and active tab so returning
-- to the menu lands back on the same row the user launched a sub-
-- screen from. Called both when the menu pauses under a pushed screen
-- (on_leave) and when it's popped off the stack (on_exit).
function Menu:_remember()
    local scroll_off = 0
    -- The scroll node is now at children[3] (title bar, tab strip,
    -- scroll). Walk defensively rather than hard-coding the index in
    -- case the layout grows another header.
    if self._tree and self._tree.children then
        for _, c in ipairs(self._tree.children) do
            if c and c.type == "scroll" then
                scroll_off = c.scroll_offset or 0
                break
            end
        end
    end
    transient.save(MENU_STATE_KEY, {
        focus   = focus_mod.index,
        scroll  = scroll_off,
        tab_idx = (self._state and self._state.tab_idx) or 1,
    })
end

function Menu:on_leave() self:_remember() end
-- on_exit is defined below; it cleans up touch subscriptions in
-- addition to remembering the selected tab.

function Menu:on_enter()
    local saved = transient.load(MENU_STATE_KEY)
    if saved then
        if saved.focus then
            -- focus.rebuild runs after this method (via _rebuild) and
            -- will clamp against the fresh chain length, so a value
            -- out of range after menu restructuring degrades
            -- gracefully.
            focus_mod.index = saved.focus
        end
    end

    -- Tap / drag for the tab strip. The strip is non-focusable so the
    -- global touch_input bridge can't translate taps there; we handle
    -- it locally using the node's recorded screen rect (set during
    -- draw) and the same per-tab width math the strip's draw uses.
    --
    -- Two gestures are supported:
    --   * Tap (down + up under TAP_SLOP px of drift): switch to the
    --     tab whose label rect contains the down point.
    --   * Horizontal drag: translate the strip's horizontal scroll
    --     offset by the finger delta. Mirrors the auto-scroll the
    --     strip does when LEFT/RIGHT cycles past the visible window.
    --
    -- Strip drag/tap thresholds.
    --  TAB_TAP_SLOP : px the finger may drift before the gesture is
    --                 reclassified as a drag. Kept tight so a real
    --                 swipe engages quickly; an honest tap rarely
    --                 drifts more than 2-3 px.
    --  STRIP_HIT_PAD: the dilated band above and below the visual
    --                 strip. Touches landing here still claim the
    --                 gesture for the strip (so a horizontal swipe
    --                 that grazes the top of the row beneath doesn't
    --                 activate it) but they're drag-only -- a tap
    --                 here doesn't switch tabs because the user
    --                 didn't really mean to land on the strip.
    local TAB_TAP_SLOP  = 4
    local STRIP_HIT_PAD = 12
    local touch_input   = require("ezui.touch_input")
    self._touch_subs = self._touch_subs or {}
    if #self._touch_subs == 0 then
        local me = self
        local pending = nil

        local function strip_widths(strip)
            theme.set_font(TAB_BAR_FONT)
            local widths, total = {}, 0
            for i, label in ipairs(strip.tabs) do
                widths[i] = theme.text_width(label) + TAB_PAD_X * 2
                total = total + widths[i]
                            + ((i < #strip.tabs) and TAB_GAP or 0)
            end
            return widths, total
        end

        local function in_strip_visual(strip, x, y)
            if not strip or not strip._x then return false end
            return y >= strip._y
                and y < strip._y + (strip._ah or 0)
                and x >= strip._x
                and x < strip._x + (strip._aw or 0)
        end

        -- Inflated band above + below the visual strip; touches here
        -- claim the gesture but only the visual rect lets a tap
        -- switch tabs.
        local function in_strip_hit(strip, x, y)
            if not strip or not strip._x then return false end
            return y >= strip._y - STRIP_HIT_PAD
                and y < strip._y + (strip._ah or 0) + STRIP_HIT_PAD
                and x >= strip._x
                and x < strip._x + (strip._aw or 0)
        end

        table.insert(self._touch_subs, ez.bus.subscribe("touch/down",
            function(_, data)
                if type(data) ~= "table" then return end
                local strip = me._tab_strip_node
                if not in_strip_hit(strip, data.x, data.y) then
                    pending = nil
                    return
                end
                -- Claim the gesture: prevents the global bridge from
                -- firing the topmost list_item if the user's finger
                -- glanced into the dilated band a few pixels below
                -- the strip.
                touch_input.claim()
                pending = {
                    x0      = data.x,
                    y0      = data.y,
                    scroll0 = strip._scroll or 0,
                    dragged = false,
                    -- Tap activation (i.e. switch tabs on lift) only
                    -- fires when the down landed on the visual strip
                    -- itself. Touches that came down in the dilated
                    -- band can drag-scroll but never switch tabs.
                    tappable = in_strip_visual(strip, data.x, data.y),
                }
            end))

        table.insert(self._touch_subs, ez.bus.subscribe("touch/move",
            function(_, data)
                if not pending or type(data) ~= "table" then return end
                local strip = me._tab_strip_node
                if not strip then return end
                local dx = data.x - pending.x0
                if math.abs(dx) > TAB_TAP_SLOP then
                    pending.dragged = true
                    local _, total = strip_widths(strip)
                    local viewport = strip._aw or 0
                    local max_off  = math.max(0, total - viewport)
                    local new_off  = pending.scroll0 - dx
                    if new_off < 0 then new_off = 0 end
                    if new_off > max_off then new_off = max_off end
                    if strip._scroll ~= new_off then
                        strip._scroll = new_off
                        require("ezui.screen").invalidate()
                    end
                end
            end))

        table.insert(self._touch_subs, ez.bus.subscribe("touch/up",
            function(_, data)
                local p = pending
                pending = nil
                if not p or p.dragged or not p.tappable
                        or type(data) ~= "table" then
                    return
                end
                local strip = me._tab_strip_node
                if not strip then return end
                local widths = strip_widths(strip)
                local scroll = strip._scroll or 0
                local rel_x  = (p.x0 - strip._x) + scroll
                local cursor = 0
                for i, w in ipairs(widths) do
                    if rel_x < cursor + w then
                        me:_set_tab(i)
                        return
                    end
                    cursor = cursor + w + TAB_GAP
                end
            end))
    end
end

function Menu:on_exit()
    self:_remember()
    if self._touch_subs then
        for _, id in ipairs(self._touch_subs) do
            ez.bus.unsubscribe(id)
        end
        self._touch_subs = nil
    end
end

function Menu:_set_tab(idx)
    if idx < 1 then idx = #CATEGORIES end
    if idx > #CATEGORIES then idx = 1 end
    if idx == (self._state and self._state.tab_idx) then return end
    -- Reset focus + scroll to the top of the new tab; keeping the old
    -- focus index would land us on a row that no longer exists once
    -- the entry list is replaced, and silently scrolled-down content
    -- looks like a stuck screen on a fresh tab open.
    focus_mod.index = 1
    -- Tell the strip its auto-scroll-to-active calculation should run
    -- on the next draw. The strip otherwise leaves the user-set
    -- scroll alone so a finger drag isn't fighting the auto-centre
    -- on every frame.
    if self._tab_strip_node then
        self._tab_strip_node._scroll_dirty = true
    end
    self:set_state({ tab_idx = idx, scroll = 0 })
end

function Menu:handle_key(key)
    if key.special == "LEFT" then
        self:_set_tab((self._state.tab_idx or 1) - 1)
        return "handled"
    elseif key.special == "RIGHT" then
        self:_set_tab((self._state.tab_idx or 1) + 1)
        return "handled"
    end
    return nil
end

function Menu:_make_item(entry)
    local on_press
    if entry.action then
        -- Direct callback. Lets the System tab's "Repeat onboarding"
        -- and "Rollback firmware" rows fire arbitrary Lua without
        -- pretending to be a sub-screen route.
        on_press = entry.action
    elseif entry.screen then
        on_press = function()
            local u = require("ezui")
            u.push_screen(entry.screen)
        end
    elseif entry.mod then
        on_press = function()
            local screen_mod = require("ezui.screen")
            local ScreenDef = require(entry.mod)
            local init = ScreenDef.initial_state and ScreenDef.initial_state() or {}
            local inst = screen_mod.create(ScreenDef, init)
            screen_mod.push(inst)
        end
    end
    return ui.list_item({
        title = entry.title,
        subtitle = entry.subtitle,
        icon = entry.icon,
        disabled = entry.disabled,
        on_press = on_press,
    })
end

return Menu
