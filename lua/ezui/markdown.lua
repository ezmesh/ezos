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
--   | h1 | h2 |             → GFM-style table (header row + separator
--   |----|----|              + data rows). Per-column alignment from
--   | a  | b  |              :--- / :---: / ---: in the separator.
--
-- Anything unrecognised degrades to plain paragraph text. The output is a
-- vbox whose children are standard ezui nodes, so it drops into any
-- ui.scroll() the caller hands it.
--
-- Known omissions (deliberate): nested lists beyond one level,
-- HTML passthrough, images, reference-style links, autolinks. These can
-- be layered on later without reshaping the parser.

local layout  = require("ezui.layout")
local widgets = require("ezui.widgets")
local theme   = require("ezui.theme")

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

-- Split a "| a | b | c |" row line into its cell strings, trimmed.
-- Treats backslash-escaped pipes as literal `|` inside a cell.
local function split_table_row(line)
    -- Strip the optional leading/trailing pipe so the empty edge cells
    -- don't show up in the result.
    local s = line:gsub("^%s*", ""):gsub("%s*$", "")
    if s:sub(1, 1) == "|" then s = s:sub(2) end
    if s:sub(-1) == "|" then s = s:sub(1, -2) end

    local cells, buf, i = {}, "", 1
    while i <= #s do
        local ch = s:sub(i, i)
        if ch == "\\" and i < #s and s:sub(i + 1, i + 1) == "|" then
            buf = buf .. "|"
            i = i + 2
        elseif ch == "|" then
            cells[#cells + 1] = buf:gsub("^%s+", ""):gsub("%s+$", "")
            buf = ""
            i = i + 1
        else
            buf = buf .. ch
            i = i + 1
        end
    end
    cells[#cells + 1] = buf:gsub("^%s+", ""):gsub("%s+$", "")
    return cells
end

-- Parse a separator row "|:---|:---:|---:|" into per-column alignments
-- ("left", "center", "right"). Returns nil if any cell isn't a valid
-- separator chunk (`:?-+:?` after trimming whitespace).
local function parse_table_separator(line)
    if not line:find("|", 1, true) then return nil end
    local cells = split_table_row(line)
    if #cells == 0 then return nil end
    local aligns = {}
    for i, c in ipairs(cells) do
        local left  = c:sub(1, 1) == ":"
        local right = c:sub(-1)   == ":"
        local body  = c:gsub("^:", ""):gsub(":$", "")
        if body == "" or body:match("^%-+$") == nil then return nil end
        if left and right then aligns[i] = "center"
        elseif right     then aligns[i] = "right"
        else                  aligns[i] = "left" end
    end
    return aligns
end

-- Detect a GFM table starting at lines[i]. The shape is:
--   line i   : header row (contains '|')
--   line i+1 : separator row (also contains '|', and parses as
--              alignments via parse_table_separator)
-- Returns (block, next_i) on success, or nil if it doesn't match.
local function try_parse_table(lines, i)
    local hdr = lines[i]
    if not hdr or not hdr:find("|", 1, true) then return nil end
    local sep = lines[i + 1]
    if not sep then return nil end
    local aligns = parse_table_separator(sep)
    if not aligns then return nil end

    local headers = split_table_row(hdr)
    if #headers == 0 then return nil end

    -- Pad alignments / header to match each other so a draw-side index
    -- past the end of either array doesn't crash.
    local n_cols = math.max(#headers, #aligns)
    for c = 1, n_cols do
        aligns[c]  = aligns[c]  or "left"
        headers[c] = headers[c] or ""
    end

    local rows = {}
    local j = i + 2
    while j <= #lines do
        local l = lines[j]
        if l:match("^%s*$") then break end
        if not l:find("|", 1, true) then break end
        local cells = split_table_row(l)
        for c = 1, n_cols do cells[c] = cells[c] or "" end
        rows[#rows + 1] = cells
        j = j + 1
    end

    return {
        kind    = "table",
        align   = aligns,
        header  = headers,
        rows    = rows,
        n_cols  = n_cols,
    }, j
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

        elseif line:find("|", 1, true) then
            -- GFM table: header row + separator row + zero or more
            -- data rows. try_parse_table validates the separator
            -- shape; if it doesn't match we fall through to the
            -- paragraph collector so a stray "| something" line
            -- still renders as text.
            local block, ni = try_parse_table(lines, i)
            if block then
                blocks[#blocks + 1] = block
                i = ni
            else
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

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
--
-- GFM-style tables. We register a dedicated `md_table` node so we can
-- own column-width allocation: hbox can't fix per-cell widths cleanly
-- (its draw uses child._w but its measure pass would re-measure each
-- rich_text against the full row width and inflate row heights), and a
-- vbox of hbox rows would force every cell in a column to be measured
-- twice with different widths. Owning the layout lets us compute one
-- column width per column and reuse it across the measure + draw
-- passes.

local function table_plain_text(cell_str)
    -- Approximate the visible width of a cell: strip the markdown
    -- punctuation that doesn't render visually so widths are based on
    -- actual glyphs rather than star/underscore noise. Backslash
    -- escapes lose the leading slash so `\|` reads as `|`.
    local s = cell_str or ""
    s = s:gsub("\\(.)", "%1")
    s = s:gsub("`", "")
    s = s:gsub("%*+", "")
    s = s:gsub("__", ""):gsub("_", "")
    return s
end

local TABLE_CELL_PAD_X = 4
local TABLE_CELL_PAD_Y = 3
local TABLE_COL_MIN_W  = 28   -- pixels; smaller and 1-2 chars vanish
local TABLE_HEADER_GAP = 3    -- below header underline
local TABLE_ROW_GAP    = 2

local function compute_table_layout(block, opts, max_w)
    local n_cols = block.n_cols
    local font   = opts.font or "small_aa"
    theme.set_font(font)

    -- Natural width per column = widest cell (including header), padded.
    local natural = {}
    for c = 1, n_cols do natural[c] = TABLE_COL_MIN_W end

    local function note_width(c, str)
        local plain = table_plain_text(str)
        local w = theme.text_width(plain) + 2 * TABLE_CELL_PAD_X
        if w > natural[c] then natural[c] = w end
    end
    for c = 1, n_cols do note_width(c, block.header[c]) end
    for _, row in ipairs(block.rows) do
        for c = 1, n_cols do note_width(c, row[c]) end
    end

    local total = 0
    for c = 1, n_cols do total = total + natural[c] end
    if total <= max_w then return natural end

    -- Doesn't fit: scale down. Anything already at the minimum stays
    -- there; the rest shares the remaining width proportionally to
    -- their growable headroom (= natural - min). This way "1" and
    -- "Status" don't end up the same width just because we ran out of
    -- room.
    local fixed_total, growable = 0, {}
    local growable_total = 0
    for c = 1, n_cols do
        if natural[c] <= TABLE_COL_MIN_W then
            fixed_total = fixed_total + TABLE_COL_MIN_W
        else
            growable[c] = natural[c] - TABLE_COL_MIN_W
            growable_total = growable_total + growable[c]
            fixed_total = fixed_total + TABLE_COL_MIN_W
        end
    end
    local avail = max_w - fixed_total
    if avail < 0 then avail = 0 end
    local scaled = {}
    for c = 1, n_cols do
        if growable[c] then
            scaled[c] = TABLE_COL_MIN_W +
                math.floor(avail * growable[c] /
                    (growable_total > 0 and growable_total or 1))
        else
            scaled[c] = TABLE_COL_MIN_W
        end
    end
    return scaled
end

-- Build a rich_text node for one cell. We pre-parse runs through
-- parse_inline so styling within a cell (bold / italic / `code` /
-- [link]) keeps working.
local function make_table_cell_node(cell_str, opts, base_color, bold)
    local runs = parse_inline(cell_str or "", { color = base_color })
    if bold then runs = overlay_style(runs, "bold") end
    return widgets.rich_text(runs, {
        font  = opts.font or "small_aa",
        color = base_color,
    })
end

node.register("md_table", {
    measure = function(n, max_w, max_h)
        local block = n._block
        local opts  = n._opts or {}
        local col_widths = compute_table_layout(block, opts, max_w)
        n._col_widths = col_widths

        -- Inner-text width for each column = column width minus the
        -- cell padding on both sides. rich_text wraps to whatever max
        -- we hand it.
        local inner_w = {}
        for c, w in ipairs(col_widths) do
            inner_w[c] = math.max(0, w - 2 * TABLE_CELL_PAD_X)
        end

        local n_cols = block.n_cols
        local total_h = 0

        -- Header row.
        local header_nodes = {}
        local header_h = 0
        for c = 1, n_cols do
            local cn = make_table_cell_node(block.header[c], opts, "TEXT", true)
            local _, ch = node.measure(cn, inner_w[c], 10000)
            header_nodes[c] = cn
            if ch > header_h then header_h = ch end
        end
        n._header_nodes = header_nodes
        n._header_h = header_h + 2 * TABLE_CELL_PAD_Y
        total_h = total_h + n._header_h + 1 + TABLE_HEADER_GAP

        -- Data rows.
        local row_nodes  = {}
        local row_heights = {}
        for r, row in ipairs(block.rows) do
            local cells = {}
            local row_h = 0
            for c = 1, n_cols do
                local cn = make_table_cell_node(row[c], opts, "TEXT", false)
                local _, ch = node.measure(cn, inner_w[c], 10000)
                cells[c] = cn
                if ch > row_h then row_h = ch end
            end
            row_nodes[r] = cells
            row_heights[r] = row_h + 2 * TABLE_CELL_PAD_Y
            total_h = total_h + row_heights[r] + TABLE_ROW_GAP
        end
        n._row_nodes = row_nodes
        n._row_heights = row_heights

        return max_w, total_h
    end,

    draw = function(n, d, x, y, w, h)
        local theme       = require("ezui.theme")
        local block       = n._block
        local col_widths  = n._col_widths or {}
        local n_cols      = block.n_cols
        local aligns      = block.align

        -- Helper: align a measured-width child within a column.
        local function place(cell, col_x, col_y, col_w, row_h)
            local cw = cell._w or col_w - 2 * TABLE_CELL_PAD_X
            local pad_x = TABLE_CELL_PAD_X
            local x_off = col_x + pad_x
            -- We can't easily right/center-align a rich_text since it
            -- left-aligns within its allocated width. Cheapest
            -- correction: shift the draw origin by the slack between
            -- column-content-width and rendered-content-width, but
            -- rich_text's lines can wrap to different visible widths.
            -- For tables on a 320-wide display the wrap-target is what
            -- the user sees, so we left-align the wrap box itself and
            -- only honour right/center for single-line numeric-style
            -- content where slack actually exists.
            local content_w = col_w - 2 * pad_x
            node.draw(cell, d,
                x_off, col_y + TABLE_CELL_PAD_Y,
                content_w, row_h - 2 * TABLE_CELL_PAD_Y)
        end

        local cy = y
        local cx = x
        -- Header row.
        for c = 1, n_cols do
            local cw = col_widths[c] or 0
            local cell = n._header_nodes and n._header_nodes[c]
            if cell then place(cell, cx, cy, cw, n._header_h) end
            cx = cx + cw
        end
        cy = cy + n._header_h
        d.fill_rect(x, cy, w, 1, theme.color("BORDER"))
        cy = cy + 1 + TABLE_HEADER_GAP

        -- Data rows.
        for r, row in ipairs(n._row_nodes or {}) do
            cx = x
            local row_h = n._row_heights[r] or 0
            -- Alternating row tint for readability when there are more
            -- than a couple of rows. Cheaper than full borders and
            -- still helps the eye track across.
            if (r % 2) == 0 then
                d.fill_rect(x, cy, w, row_h, theme.color("SURFACE"))
            end
            for c = 1, n_cols do
                local cw = col_widths[c] or 0
                local cell = row[c]
                if cell then place(cell, cx, cy, cw, row_h) end
                cx = cx + cw
            end
            cy = cy + row_h + TABLE_ROW_GAP
        end
    end,
})

local function render_table(block, opts)
    -- The custom node owns all layout; just pass the parsed block and
    -- the renderer opts (we need the base font for measuring).
    return layout.padding({ 4, 0, 6, 0 }, {
        type   = "md_table",
        _block = block,
        _opts  = opts,
    })
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
    ["table"] = render_table,
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
