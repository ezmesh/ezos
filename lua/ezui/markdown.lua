-- ezui.markdown: render a subset of Markdown as an ezui node tree.
--
-- Covers the features that actually matter for on-device docs / changelogs
-- / credits / read-only help screens:
--
--   # H1 .. ### H3         → larger, bold headings
--   paragraph text         → rich_text, wraps to viewport width
--   *italic* _italic_      → italic run
--   **bold** __bold__      → bold run
--   ***both***             → bold + italic
--   `inline code`          → mono (bitmap Spleen), for visual contrast
--   [label](url)           → underlined run (no link navigation yet)
--   ```fenced code```      → block code in mono, background-tinted
--   > quote                → left-bar + indented rich_text
--   - item / * item        → bulleted lists
--   1. item                → numbered lists
--   --- / ***              → horizontal rule
--
-- Anything unrecognised degrades to plain paragraph text. The output is a
-- vbox whose children are standard ezui nodes, so it drops into any
-- ui.scroll() the caller hands it.
--
-- Known omissions (deliberate): nested lists beyond one level, tables,
-- HTML passthrough, images, reference-style links, autolinks. These can
-- be layered on later without reshaping the parser.

local layout  = require("ezui.layout")
local widgets = require("ezui.widgets")

local M = {}

-- ---------------------------------------------------------------------------
-- Inline parser
-- ---------------------------------------------------------------------------

-- Parse one line of source text into a list of runs ready for rich_text.
-- `opts` carries the base font and default color that unstyled runs use.
local function parse_inline(source, opts)
    opts = opts or {}
    local base_color = opts.color or "TEXT"
    local code_color = opts.code_color or "INFO"
    local link_color = opts.link_color or "ACCENT"

    local runs = {}
    local i = 1
    local n = #source
    local buf = ""

    local function flush_buf(style)
        if buf ~= "" then
            runs[#runs + 1] = { t = buf, style = style or "regular", color = base_color }
            buf = ""
        end
    end

    -- Read ahead and match a run of the same delimiter. Returns the inner
    -- text and the new index, or nil if no match.
    local function match_delim(delim)
        local dl = #delim
        -- Ensure we're sitting on the opening delimiter.
        if source:sub(i, i + dl - 1) ~= delim then return nil end
        -- Find a closing delimiter somewhere after.
        local search_from = i + dl
        while search_from <= n - dl + 1 do
            local cand = source:find(delim, search_from, true)
            if not cand then return nil end
            -- Require the inner content to be non-empty so "**" on its own
            -- isn't swallowed as an empty bold run.
            if cand > i + dl then
                local inner = source:sub(i + dl, cand - 1)
                return inner, cand + dl
            end
            search_from = cand + dl
        end
        return nil
    end

    while i <= n do
        local ch = source:sub(i, i)

        -- Backslash-escape: the next character is emitted as-is without
        -- inline interpretation. Lets docs embed literal * or _ etc.
        if ch == "\\" and i < n then
            buf = buf .. source:sub(i + 1, i + 1)
            i = i + 2

        -- Triple-star: bold + italic. Checked before ** and * because
        -- match_delim('**') would match the '**' inside '***'.
        elseif ch == "*" and source:sub(i, i + 2) == "***" then
            local inner, ni = match_delim("***")
            if inner then
                flush_buf()
                runs[#runs + 1] = { t = inner, style = "bold_italic", color = base_color }
                i = ni
            else
                buf = buf .. ch
                i = i + 1
            end

        elseif (ch == "*" or ch == "_") and source:sub(i, i + 1) == ch .. ch then
            local inner, ni = match_delim(ch .. ch)
            if inner then
                flush_buf()
                runs[#runs + 1] = { t = inner, style = "bold", color = base_color }
                i = ni
            else
                buf = buf .. ch
                i = i + 1
            end

        elseif ch == "*" or ch == "_" then
            -- Single-delim italic. Underscore italics only trigger at a
            -- word boundary so that snake_case words survive intact.
            local is_boundary = (ch == "*")
                or (i == 1 or source:sub(i - 1, i - 1):match("[%s%p]") ~= nil)
            -- NB: we need both return values from match_delim, so assign
            -- directly — wrapping this in `and/or` would drop `ni` (Lua
            -- collapses multi-returns inside expressions).
            local inner, ni
            if is_boundary then inner, ni = match_delim(ch) end
            if inner then
                flush_buf()
                runs[#runs + 1] = { t = inner, style = "italic", color = base_color }
                i = ni
            else
                buf = buf .. ch
                i = i + 1
            end

        elseif ch == "`" then
            local close = source:find("`", i + 1, true)
            if close then
                local inner = source:sub(i + 1, close - 1)
                flush_buf()
                runs[#runs + 1] = { t = inner, mono = true, color = code_color }
                i = close + 1
            else
                buf = buf .. ch
                i = i + 1
            end

        elseif ch == "[" then
            -- Minimal [text](url) matcher. Bail out cleanly if the shape
            -- doesn't match — no hidden partial consumption.
            local label_end = source:find("]", i + 1, true)
            local ok = false
            if label_end and source:sub(label_end + 1, label_end + 1) == "(" then
                local url_end = source:find(")", label_end + 2, true)
                if url_end then
                    local label = source:sub(i + 1, label_end - 1)
                    flush_buf()
                    runs[#runs + 1] = {
                        t = label, style = "regular",
                        color = link_color, under = true,
                    }
                    i = url_end + 1
                    ok = true
                end
            end
            if not ok then
                buf = buf .. ch
                i = i + 1
            end

        else
            buf = buf .. ch
            i = i + 1
        end
    end

    flush_buf()
    return runs
end

-- ---------------------------------------------------------------------------
-- Block parser
-- ---------------------------------------------------------------------------

local function lines_of(src)
    local out = {}
    -- gmatch with "([^\n]*)\n" drops the final line if unterminated, so
    -- append an explicit newline to make the pattern regular.
    for line in (src .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = line
    end
    return out
end

local function is_hrule(line)
    local stripped = line:gsub("%s", "")
    if #stripped < 3 then return false end
    return stripped:match("^%-+$") or stripped:match("^%*+$") or stripped:match("^_+$")
end

local function parse_blocks(src)
    local lines = lines_of(src)
    local blocks = {}
    local i = 1

    while i <= #lines do
        local line = lines[i]

        if line:match("^%s*$") then
            i = i + 1

        elseif line:match("^```") then
            -- Fenced code block: consume until the next line starting ```.
            local lang = line:match("^```%s*(%S*)") or ""
            local code_lines = {}
            i = i + 1
            while i <= #lines and not lines[i]:match("^```") do
                code_lines[#code_lines + 1] = lines[i]
                i = i + 1
            end
            -- Skip closing fence (tolerate missing one at EOF).
            if i <= #lines then i = i + 1 end
            blocks[#blocks + 1] = {
                kind = "code",
                text = table.concat(code_lines, "\n"),
                lang = lang,
            }

        elseif is_hrule(line) then
            blocks[#blocks + 1] = { kind = "hr" }
            i = i + 1

        elseif line:match("^%s*#") then
            local hashes, rest = line:match("^%s*(#+)%s*(.*)$")
            local level = math.min(3, #hashes)
            blocks[#blocks + 1] = {
                kind = "heading",
                level = level,
                runs = parse_inline(rest or ""),
            }
            i = i + 1

        elseif line:match("^%s*>%s?") then
            -- Consume consecutive quote lines into one block, soft-joined
            -- with spaces so the wrapped paragraph flows.
            local parts = {}
            while i <= #lines and lines[i]:match("^%s*>%s?") do
                parts[#parts + 1] = lines[i]:gsub("^%s*>%s?", "")
                i = i + 1
            end
            blocks[#blocks + 1] = {
                kind = "quote",
                runs = parse_inline(table.concat(parts, " ")),
            }

        elseif line:match("^%s*[%-%*]%s+") or line:match("^%s*%d+%.%s+") then
            -- Collect a run of list items. The first item's marker kind
            -- (bullet vs. ordered) sets the block kind; we don't support
            -- switching mid-list, same as CommonMark's behaviour.
            local ordered = line:match("^%s*%d+%.%s+") ~= nil
            local items = {}
            while i <= #lines do
                local l = lines[i]
                local is_bullet = l:match("^%s*[%-%*]%s+") ~= nil
                local is_ordered = l:match("^%s*%d+%.%s+") ~= nil
                if not (is_bullet or is_ordered) then break end
                if ordered and is_bullet then break end
                if (not ordered) and is_ordered then break end
                local content
                if ordered then
                    content = l:gsub("^%s*%d+%.%s+", "")
                else
                    content = l:gsub("^%s*[%-%*]%s+", "")
                end
                -- Support paragraph-like continuation lines (indented by
                -- more than the marker). Each appended line is joined
                -- with a space so wrapping still collapses whitespace.
                i = i + 1
                while i <= #lines and lines[i]:match("^%s%s+%S") do
                    content = content .. " " .. lines[i]:gsub("^%s+", "")
                    i = i + 1
                end
                items[#items + 1] = parse_inline(content)
            end
            blocks[#blocks + 1] = {
                kind = ordered and "olist" or "ulist",
                items = items,
            }

        else
            -- Collect consecutive non-blank, non-special lines into one
            -- paragraph. Soft line breaks collapse to spaces.
            local parts = { line }
            i = i + 1
            while i <= #lines do
                local l = lines[i]
                if l:match("^%s*$") then break end
                if l:match("^%s*#") then break end
                if l:match("^```") then break end
                if is_hrule(l) then break end
                if l:match("^%s*>%s?") then break end
                if l:match("^%s*[%-%*]%s+") or l:match("^%s*%d+%.%s+") then break end
                parts[#parts + 1] = l
                i = i + 1
            end
            blocks[#blocks + 1] = {
                kind = "para",
                runs = parse_inline(table.concat(parts, " ")),
            }
        end
    end

    return blocks
end

-- ---------------------------------------------------------------------------
-- Render blocks → node tree
-- ---------------------------------------------------------------------------

-- Font sizing decisions live here so they're easy to tune without touching
-- the parser. H1 is the only size jump; H2/H3 use the base size with
-- weight / colour for hierarchy, which reads better on a 320-wide panel
-- than three escalating sizes would.
local HEADING_FONT = {
    [1] = "medium_aa",
    [2] = "small_aa",
    [3] = "small_aa",
}
local HEADING_GAP_BEFORE = { [1] = 10, [2] = 8, [3] = 6 }
local HEADING_GAP_AFTER  = { [1] = 4,  [2] = 3, [3] = 2 }

-- Apply an outer style (bold / italic) across every run in `runs`. Used
-- for headings and blockquotes where the whole line should be styled but
-- per-run inline emphasis should still win (e.g. a code span stays mono).
local function overlay_style(runs, outer)
    local out = {}
    for _, r in ipairs(runs) do
        local copy = {}
        for k, v in pairs(r) do copy[k] = v end
        if outer == "bold" and copy.style == "italic" then
            copy.style = "bold_italic"
        elseif outer == "italic" and copy.style == "bold" then
            copy.style = "bold_italic"
        elseif not copy.mono then
            copy.style = outer
        end
        out[#out + 1] = copy
    end
    return out
end

local function render_heading(block, opts)
    local font = HEADING_FONT[block.level] or "small_aa"
    local color = (block.level == 1) and "TEXT" or "ACCENT"
    local runs = overlay_style(block.runs, "bold")
    -- Headings always render bold + highlighted. `color` on the rich_text
    -- node is the default; individual runs can still override it.
    local rt = widgets.rich_text(runs, { font = font, color = color })
    return layout.padding(
        { HEADING_GAP_BEFORE[block.level] or 6, 0, HEADING_GAP_AFTER[block.level] or 3, 0 },
        rt
    )
end

local function render_para(block, opts)
    local rt = widgets.rich_text(block.runs, {
        font = opts.font or "small_aa",
        color = "TEXT",
    })
    return layout.padding({ 2, 0, 2, 0 }, rt)
end

-- Register a one-off quote block: left-bar + indented italic rich text.
-- We can't compose this from hbox + divider because an hbox measures its
-- children at `max_h` (effectively unbounded inside a scroll), which makes
-- a vertical divider claim 10 000 px and push every following block off
-- the bottom of the scroll area. Owning the layout here lets us tie the
-- bar's height to the rich_text's measured height.
local node = require("ezui.node")

node.register("md_quote", {
    measure = function(n, max_w, max_h)
        local rt = n.children and n.children[1]
        if rt then
            local bar_w = 2
            local gap   = 8
            local left_inset = bar_w + gap
            local _, ch = node.measure(rt, max_w - left_inset, max_h)
            return max_w, ch
        end
        return max_w, 0
    end,

    draw = function(n, d, x, y, w, h)
        local bar_w = 2
        local gap   = 8
        local theme = require("ezui.theme")
        d.fill_rect(x, y, bar_w, h, theme.color("BORDER"))
        local rt = n.children and n.children[1]
        if rt then
            node.draw(rt, d, x + bar_w + gap, y, w - bar_w - gap, h)
        end
    end,
})

local function render_quote(block, opts)
    local runs = overlay_style(block.runs, "italic")
    local rt = widgets.rich_text(runs, {
        font = opts.font or "small_aa",
        color = "TEXT_SEC",
    })
    return layout.padding({ 4, 0, 4, 0 }, {
        type = "md_quote",
        children = { rt },
    })
end

local function render_code(block, opts)
    -- Block code: mono font at a size that roughly matches the base AA
    -- size, wrapped in a tinted vbox so it reads as a distinct chunk.
    -- (`padding` has no background of its own, so a vbox is the cheapest
    -- way to get both an inset and a fill.)
    local mono_size = "small"
    if opts.font == "tiny_aa" then mono_size = "tiny" end
    local text_node = widgets.text(block.text, {
        font = mono_size,
        color = "INFO",
        wrap = true,
    })
    return layout.vbox({ bg = "SURFACE" }, {
        layout.padding({ 6, 8, 6, 8 }, text_node),
    })
end

local function render_hr(block, opts)
    return layout.padding({ 6, 0, 6, 0 },
        layout.divider({ color = "BORDER" })
    )
end

local function render_list(block, opts, ordered)
    local children = {}
    for idx, item_runs in ipairs(block.items) do
        local marker = ordered and (tostring(idx) .. ".") or "-"
        local marker_node = widgets.text(marker, {
            font = opts.font or "small_aa",
            color = "TEXT_MUTED",
            -- Fixed marker width keeps item text aligned vertically
            -- regardless of marker length (1. vs 10. would drift).
        })
        -- Hint the marker's measured width so the hbox doesn't grow it.
        marker_node._w = ordered and 18 or 10
        local rt = widgets.rich_text(item_runs, {
            font = opts.font or "small_aa",
            color = "TEXT",
        })
        -- Let the rich_text fill remaining width.
        rt.grow = 1
        children[#children + 1] = layout.padding({ 1, 0, 1, 0 },
            layout.hbox({ gap = 4 }, { marker_node, rt })
        )
    end
    return layout.vbox({ gap = 0 }, children)
end

local RENDERERS = {
    heading = render_heading,
    para    = render_para,
    quote   = render_quote,
    code    = render_code,
    hr      = render_hr,
    ulist   = function(b, o) return render_list(b, o, false) end,
    olist   = function(b, o) return render_list(b, o, true)  end,
}

-- Public entry: render a markdown source string into a single node (a
-- vbox of child blocks) ready to drop under a ui.scroll().
function M.render(source, opts)
    opts = opts or {}
    opts.font = opts.font or "small_aa"

    local blocks = parse_blocks(source or "")
    local children = {}
    for _, b in ipairs(blocks) do
        local r = RENDERERS[b.kind]
        if r then children[#children + 1] = r(b, opts) end
    end

    return layout.vbox({ gap = 2, bg = opts.bg }, children)
end

-- Expose parse for tests or advanced callers that want to intercept the
-- block tree before rendering.
M.parse_blocks = parse_blocks
M.parse_inline = parse_inline

return M
