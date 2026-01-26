-- text_utils.lua - Text measurement and wrapping utilities
-- Uses display.text_width() for accurate pixel-based measurements

local TextUtils = {}

-- Wrap text to fit within max_pixel_width
-- Returns array of lines that fit within the specified pixel width
-- Uses word-breaking: tries to break at spaces, falls back to character break
function TextUtils.wrap_text(text, max_pixel_width, display)
    if not text or text == "" then
        return {""}
    end

    local lines = {}
    local words = {}

    -- Split text into words (preserve spaces for accurate measurement)
    for word in text:gmatch("%S+") do
        table.insert(words, word)
    end

    if #words == 0 then
        return {""}
    end

    local current_line = ""
    local space_width = display.text_width(" ")

    for i, word in ipairs(words) do
        local word_width = display.text_width(word)

        -- Check if word alone is too wide (need to break it)
        if word_width > max_pixel_width then
            -- Finish current line if any
            if current_line ~= "" then
                table.insert(lines, current_line)
                current_line = ""
            end

            -- Break word character by character
            local partial = ""
            for j = 1, #word do
                local char = word:sub(j, j)
                local test = partial .. char
                if display.text_width(test) > max_pixel_width then
                    if partial ~= "" then
                        table.insert(lines, partial)
                    end
                    partial = char
                else
                    partial = test
                end
            end
            current_line = partial
        else
            -- Normal word - try to add to current line
            local test_line
            if current_line == "" then
                test_line = word
            else
                test_line = current_line .. " " .. word
            end

            if display.text_width(test_line) <= max_pixel_width then
                current_line = test_line
            else
                -- Line would be too wide, start new line
                if current_line ~= "" then
                    table.insert(lines, current_line)
                end
                current_line = word
            end
        end
    end

    -- Add final line
    if current_line ~= "" then
        table.insert(lines, current_line)
    end

    if #lines == 0 then
        return {""}
    end

    return lines
end

-- Wrap text to fit within max_chars columns (for monospace fonts)
-- Simpler version when we know font is monospace
function TextUtils.wrap_text_cols(text, max_cols)
    if not text or text == "" then
        return {""}
    end

    local lines = {}
    local remaining = text

    while #remaining > 0 do
        if #remaining <= max_cols then
            table.insert(lines, remaining)
            break
        end

        -- Find last space within max_cols
        local break_pos = max_cols
        local space_pos = remaining:sub(1, max_cols):match(".*()%s")
        if space_pos and space_pos > 1 then
            break_pos = space_pos - 1
        end

        table.insert(lines, remaining:sub(1, break_pos))
        remaining = remaining:sub(break_pos + 1):gsub("^%s+", "")  -- Trim leading space
    end

    if #lines == 0 then
        return {""}
    end

    return lines
end

-- Measure string width using display.text_width
-- Returns width in pixels
function TextUtils.measure(text, display)
    if not text or text == "" then
        return 0
    end
    return display.text_width(text)
end

-- Truncate text to fit within max_pixel_width, adding ellipsis if truncated
function TextUtils.truncate(text, max_pixel_width, display)
    if not text or text == "" then
        return ""
    end

    if display.text_width(text) <= max_pixel_width then
        return text
    end

    local ellipsis = "..."
    local ellipsis_width = display.text_width(ellipsis)
    local target_width = max_pixel_width - ellipsis_width

    if target_width <= 0 then
        return ellipsis
    end

    -- Binary search for the right length
    local result = ""
    for i = 1, #text do
        local test = text:sub(1, i)
        if display.text_width(test) > target_width then
            break
        end
        result = test
    end

    return result .. ellipsis
end

return TextUtils
