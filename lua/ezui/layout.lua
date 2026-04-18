-- ezui.layout: Layout containers
-- VBox, HBox, ZStack, Padding, Scroll, Spacer
-- Each is a node type registered with the node system.

local node = require("ezui.node")
local theme = require("ezui.theme")

local layout = {}

-- Helper: resolve padding shorthand
-- padding = number | {top, right, bottom, left} | {vertical, horizontal}
local function resolve_pad(p)
    if not p then return 0, 0, 0, 0 end
    if type(p) == "number" then return p, p, p, p end
    if #p == 2 then return p[1], p[2], p[1], p[2] end
    return p[1] or 0, p[2] or 0, p[3] or 0, p[4] or 0
end

-- ---------------------------------------------------------------------------
-- VBox: vertical stack
-- ---------------------------------------------------------------------------

node.register("vbox", {
    measure = function(n, max_w, max_h)
        local pt, pr, pb, pl = resolve_pad(n.padding)
        local gap = n.gap or 0
        local inner_w = max_w - pl - pr
        local total_h = 0
        local max_child_w = 0

        if n.children then
            for i, child in ipairs(n.children) do
                local cw, ch = node.measure(child, inner_w, max_h - total_h - pt - pb)
                if cw > max_child_w then max_child_w = cw end
                total_h = total_h + ch
                if i < #n.children then total_h = total_h + gap end
            end
        end

        local w = max_w  -- VBox stretches to fill width by default
        local h = total_h + pt + pb
        return w, h
    end,

    draw = function(n, d, x, y, w, h)
        local pt, pr, pb, pl = resolve_pad(n.padding)
        local gap = n.gap or 0
        local inner_w = w - pl - pr
        local cy = y + pt

        -- Optional background
        if n.bg then
            d.fill_rect(x, y, w, h, theme.color(n.bg))
        end

        if n.children then
            -- Calculate total fixed height and count grow children
            local total_fixed = 0
            local total_grow = 0
            for i, child in ipairs(n.children) do
                if child.grow and child.grow > 0 then
                    total_grow = total_grow + child.grow
                else
                    total_fixed = total_fixed + (child._h or 0)
                end
                if i < #n.children then total_fixed = total_fixed + gap end
            end

            local avail = h - pt - pb - total_fixed
            if avail < 0 then avail = 0 end

            for i, child in ipairs(n.children) do
                local ch
                if child.grow and child.grow > 0 and total_grow > 0 then
                    ch = math.floor(avail * child.grow / total_grow)
                else
                    ch = child._h or 0
                end

                -- Cross-axis alignment
                local cx = x + pl
                local cw = inner_w
                local align = child.align or n.align or "stretch"
                if align == "center" then
                    cx = x + pl + math.floor((inner_w - (child._w or 0)) / 2)
                    cw = child._w or inner_w
                elseif align == "end" then
                    cx = x + pl + inner_w - (child._w or 0)
                    cw = child._w or inner_w
                elseif align == "start" then
                    cw = child._w or inner_w
                end

                node.draw(child, d, cx, cy, cw, ch)
                cy = cy + ch + gap
            end
        end
    end,
})

-- ---------------------------------------------------------------------------
-- HBox: horizontal stack
-- ---------------------------------------------------------------------------

node.register("hbox", {
    measure = function(n, max_w, max_h)
        local pt, pr, pb, pl = resolve_pad(n.padding)
        local gap = n.gap or 0
        local inner_h = max_h - pt - pb
        local total_w = 0
        local max_child_h = 0

        if n.children then
            for i, child in ipairs(n.children) do
                local cw, ch = node.measure(child, max_w - total_w - pl - pr, inner_h)
                if ch > max_child_h then max_child_h = ch end
                total_w = total_w + cw
                if i < #n.children then total_w = total_w + gap end
            end
        end

        return total_w + pl + pr, max_child_h + pt + pb
    end,

    draw = function(n, d, x, y, w, h)
        local pt, pr, pb, pl = resolve_pad(n.padding)
        local gap = n.gap or 0
        local inner_h = h - pt - pb
        local cx = x + pl

        if n.bg then
            d.fill_rect(x, y, w, h, theme.color(n.bg))
        end

        if n.children then
            -- Calculate grow distribution
            local total_fixed = 0
            local total_grow = 0
            for i, child in ipairs(n.children) do
                if child.grow and child.grow > 0 then
                    total_grow = total_grow + child.grow
                else
                    total_fixed = total_fixed + (child._w or 0)
                end
                if i < #n.children then total_fixed = total_fixed + gap end
            end

            local avail = w - pl - pr - total_fixed
            if avail < 0 then avail = 0 end

            for i, child in ipairs(n.children) do
                local cw
                if child.grow and child.grow > 0 and total_grow > 0 then
                    cw = math.floor(avail * child.grow / total_grow)
                else
                    cw = child._w or 0
                end

                local cy = y + pt
                local ch = inner_h
                local align = child.align or n.align or "stretch"
                if align == "center" then
                    cy = y + pt + math.floor((inner_h - (child._h or 0)) / 2)
                    ch = child._h or inner_h
                elseif align == "start" then
                    ch = child._h or inner_h
                elseif align == "end" then
                    cy = y + pt + inner_h - (child._h or 0)
                    ch = child._h or inner_h
                end

                node.draw(child, d, cx, cy, cw, ch)
                cx = cx + cw + gap
            end
        end
    end,
})

-- ---------------------------------------------------------------------------
-- ZStack: overlapping layers (children drawn back to front)
-- ---------------------------------------------------------------------------

node.register("zstack", {
    measure = function(n, max_w, max_h)
        local max_cw, max_ch = 0, 0
        if n.children then
            for _, child in ipairs(n.children) do
                local cw, ch = node.measure(child, max_w, max_h)
                if cw > max_cw then max_cw = cw end
                if ch > max_ch then max_ch = ch end
            end
        end
        return max_w, max_ch
    end,

    draw = function(n, d, x, y, w, h)
        if n.bg then
            d.fill_rect(x, y, w, h, theme.color(n.bg))
        end
        if n.children then
            for _, child in ipairs(n.children) do
                node.draw(child, d, x, y, w, h)
            end
        end
    end,
})

-- ---------------------------------------------------------------------------
-- Padding: inset wrapper
-- ---------------------------------------------------------------------------

node.register("padding", {
    measure = function(n, max_w, max_h)
        local pt, pr, pb, pl = resolve_pad(n.pad)
        local child = n.children and n.children[1]
        if child then
            local cw, ch = node.measure(child, max_w - pl - pr, max_h - pt - pb)
            return cw + pl + pr, ch + pt + pb
        end
        return pl + pr, pt + pb
    end,

    draw = function(n, d, x, y, w, h)
        local pt, pr, pb, pl = resolve_pad(n.pad)
        local child = n.children and n.children[1]
        if child then
            node.draw(child, d, x + pl, y + pt, w - pl - pr, h - pt - pb)
        end
    end,
})

-- ---------------------------------------------------------------------------
-- Scroll: scrollable viewport with clip rect
-- ---------------------------------------------------------------------------

node.register("scroll", {
    measure = function(n, max_w, max_h)
        -- Measure content at unlimited height to find total content height
        local child = n.children and n.children[1]
        if child then
            node.measure(child, max_w, 10000)
            n._content_h = child._h or 0
        else
            n._content_h = 0
        end
        -- Scroll itself takes whatever height is offered
        return max_w, max_h
    end,

    draw = function(n, d, x, y, w, h)
        local offset = n.scroll_offset or 0
        local content_h = n._content_h or 0

        -- Clamp scroll offset
        local max_scroll = content_h - h
        if max_scroll < 0 then max_scroll = 0 end
        if offset > max_scroll then offset = max_scroll end
        if offset < 0 then offset = 0 end
        n.scroll_offset = offset

        -- Background
        if n.bg then
            d.fill_rect(x, y, w, h, theme.color(n.bg))
        end

        -- Set hardware clip rect, draw content shifted by scroll offset, then clear.
        -- pcall ensures clip rect is always cleared even if draw errors.
        d.set_clip_rect(x, y, w, h)
        local child = n.children and n.children[1]
        if child then
            local ok, err = pcall(node.draw, child, d, x, y - offset, w, content_h)
            if not ok then
                ez.log("[Scroll] draw error: " .. tostring(err))
            end
        end
        d.clear_clip_rect()

        -- Draw scrollbar if content overflows
        if content_h > h then
            local bar_x = x + w - 3
            local bar_h = h
            local thumb_h = math.max(8, math.floor(h * h / content_h))
            local thumb_y = y + math.floor(offset * (bar_h - thumb_h) / max_scroll)
            d.fill_rect(bar_x, y, 3, bar_h, theme.color("SCROLLBAR"))
            d.fill_rect(bar_x, thumb_y, 3, thumb_h, theme.color("SCROLLBAR_T"))
        end
    end,
})

-- ---------------------------------------------------------------------------
-- Spacer: flexible empty space
-- ---------------------------------------------------------------------------

node.register("spacer", {
    measure = function(n, max_w, max_h)
        -- Spacers have zero natural size; they grow to fill via the grow property
        return n.w or 0, n.h or 0
    end,

    draw = function(n, d, x, y, w, h)
        -- Nothing to draw
    end,
})

-- ---------------------------------------------------------------------------
-- Divider: horizontal or vertical line
-- ---------------------------------------------------------------------------

node.register("divider", {
    measure = function(n, max_w, max_h)
        local thickness = n.thickness or 1
        if n.vertical then
            return thickness, max_h
        end
        return max_w, thickness
    end,

    draw = function(n, d, x, y, w, h)
        local color = theme.color(n.color or "BORDER")
        d.fill_rect(x, y, w, h, color)
    end,
})

-- ---------------------------------------------------------------------------
-- Constructor helpers
-- ---------------------------------------------------------------------------

function layout.vbox(props, children)
    props = props or {}
    props.type = "vbox"
    props.children = children
    return props
end

function layout.hbox(props, children)
    props = props or {}
    props.type = "hbox"
    props.children = children
    return props
end

function layout.zstack(props, children)
    props = props or {}
    props.type = "zstack"
    props.children = children
    return props
end

function layout.padding(pad, child)
    return { type = "padding", pad = pad, children = { child } }
end

function layout.scroll(props, child)
    props = props or {}
    props.type = "scroll"
    props.children = { child }
    return props
end

function layout.spacer(props)
    props = props or {}
    props.type = "spacer"
    if not props.grow then props.grow = 1 end
    return props
end

function layout.divider(props)
    props = props or {}
    props.type = "divider"
    return props
end

return layout
