-- bitmap.lua - Bitmap loading and display utilities
-- Loads RGB565 bitmap files and provides helper functions

local Bitmap = {}

-- Default transparent color (magenta in RGB565)
Bitmap.TRANSPARENT = 0xF81F

-- Internal: parse bitmap data and return bitmap table
local function parse_bitmap_data(data, path, size)
    if not data then
        tdeck.system.log("Bitmap: Failed to load " .. path)
        return nil
    end

    -- For RGB565: data_length = width * height * 2
    local pixel_count = #data / 2
    local width, height

    if type(size) == "table" then
        -- Explicit width/height provided
        width = size[1] or size.width
        height = size[2] or size.height
    elseif type(size) == "number" then
        -- Square image
        width = size
        height = size
    else
        -- Try to guess from common sizes
        local sqrt = math.sqrt(pixel_count)
        if sqrt == math.floor(sqrt) then
            width = sqrt
            height = sqrt
        else
            tdeck.system.log("Bitmap: Cannot determine size for " .. path)
            return nil
        end
    end

    if #data < width * height * 2 then
        tdeck.system.log("Bitmap: File too small for " .. width .. "x" .. height)
        return nil
    end

    return {
        width = width,
        height = height,
        data = data
    }
end

-- Load a bitmap from file (synchronous)
-- Returns: {width, height, data} or nil on error
-- size can be a number (for square images) or {width, height} table
function Bitmap.load(path, size)
    local data = tdeck.storage.read_file(path)
    return parse_bitmap_data(data, path, size)
end

-- Load a bitmap asynchronously (must be called from a coroutine)
-- Returns: {width, height, data} or nil on error
function Bitmap.load_async(path, size)
    local data = async_read(path)
    return parse_bitmap_data(data, path, size)
end

-- Load a bitmap with callback (non-blocking)
-- callback(bitmap) is called when loading completes
function Bitmap.load_with_callback(path, size, callback)
    local function do_load()
        local data = async_read(path)
        local bitmap = parse_bitmap_data(data, path, size)
        if callback then
            callback(bitmap)
        end
    end

    spawn(do_load)
end

-- Load bitmap with size from path pattern (e.g., /icons/24x24/actions/go-home.rgb565)
function Bitmap.load_icon(category, name, size)
    size = size or 24
    local path = string.format("/icons/%dx%d/%s/%s.rgb565", size, size, category, name)
    return Bitmap.load(path, size)
end

-- Draw a bitmap at position
function Bitmap.draw(bitmap, x, y)
    if bitmap and bitmap.data then
        tdeck.display.draw_bitmap(x, y, bitmap.width, bitmap.height, bitmap.data)
    end
end

-- Draw a bitmap with transparency
function Bitmap.draw_transparent(bitmap, x, y, transparent_color)
    transparent_color = transparent_color or Bitmap.TRANSPARENT
    if bitmap and bitmap.data then
        tdeck.display.draw_bitmap_transparent(
            x, y, bitmap.width, bitmap.height, bitmap.data, transparent_color
        )
    end
end

-- Draw centered on screen
function Bitmap.draw_centered(bitmap)
    if bitmap and bitmap.data then
        local screen_w = tdeck.display.get_width()
        local screen_h = tdeck.display.get_height()
        local x = math.floor((screen_w - bitmap.width) / 2)
        local y = math.floor((screen_h - bitmap.height) / 2)
        Bitmap.draw(bitmap, x, y)
    end
end

-- Draw centered with transparency
function Bitmap.draw_centered_transparent(bitmap, transparent_color)
    transparent_color = transparent_color or Bitmap.TRANSPARENT
    if bitmap and bitmap.data then
        local screen_w = tdeck.display.get_width()
        local screen_h = tdeck.display.get_height()
        local x = math.floor((screen_w - bitmap.width) / 2)
        local y = math.floor((screen_h - bitmap.height) / 2)
        Bitmap.draw_transparent(bitmap, x, y, transparent_color)
    end
end

return Bitmap
