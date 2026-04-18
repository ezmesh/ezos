-- ezui.text: Text measurement, word wrapping, and truncation
-- Works with the C++ display.text_width() for pixel-accurate layout.

local text = {}

-- Wrap text to fit within max_width pixels.
-- Returns a list of lines (strings).
-- Uses word-break with character-break fallback for long words.
function text.wrap(str, max_width)
    if not str or str == "" then return { "" } end

    local tw = ez.display.text_width
    if tw(str) <= max_width then return { str } end

    local lines = {}
    -- Split on existing newlines first
    for segment in str:gmatch("([^\n]*)\n?") do
        if segment == "" and #lines > 0 then
            -- Preserve blank lines from explicit newlines
            lines[#lines + 1] = ""
        else
            text._wrap_segment(segment, max_width, tw, lines)
        end
    end

    if #lines == 0 then lines[1] = "" end
    return lines
end

function text._wrap_segment(segment, max_width, tw, lines)
    if segment == "" then
        lines[#lines + 1] = ""
        return
    end
    if tw(segment) <= max_width then
        lines[#lines + 1] = segment
        return
    end

    local words = {}
    for word in segment:gmatch("%S+") do
        words[#words + 1] = word
    end

    local line = ""
    for _, word in ipairs(words) do
        if line == "" then
            -- First word on line - character-break if it's too long
            if tw(word) > max_width then
                text._char_break(word, max_width, tw, lines)
                line = ""
            else
                line = word
            end
        else
            local test = line .. " " .. word
            if tw(test) <= max_width then
                line = test
            else
                lines[#lines + 1] = line
                if tw(word) > max_width then
                    text._char_break(word, max_width, tw, lines)
                    line = ""
                else
                    line = word
                end
            end
        end
    end
    if line ~= "" then
        lines[#lines + 1] = line
    end
end

function text._char_break(word, max_width, tw, lines)
    local buf = ""
    for i = 1, #word do
        local ch = word:sub(i, i)
        local test = buf .. ch
        if tw(test) > max_width and buf ~= "" then
            lines[#lines + 1] = buf
            buf = ch
        else
            buf = test
        end
    end
    if buf ~= "" then
        lines[#lines + 1] = buf
    end
end

-- Truncate text to fit max_width pixels, adding ellipsis if needed.
function text.truncate(str, max_width)
    if not str then return "" end
    local tw = ez.display.text_width
    if tw(str) <= max_width then return str end

    local ellipsis = ".."
    local ew = tw(ellipsis)
    local target = max_width - ew
    if target <= 0 then return ellipsis end

    local buf = ""
    for i = 1, #str do
        local test = buf .. str:sub(i, i)
        if tw(test) > target then
            return buf .. ellipsis
        end
        buf = test
    end
    return buf .. ellipsis
end

-- Count the number of lines text would wrap to at max_width
function text.line_count(str, max_width)
    return #text.wrap(str, max_width)
end

return text
