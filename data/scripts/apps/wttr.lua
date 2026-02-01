-- Weather script using wttr.in
-- Fetches current weather for a location
--
-- Usage:
--   Terminal: run /scripts/apps/wttr.lua
--   Lua: spawn_module("/scripts/apps/wttr.lua", "main", "Amsterdam")

local Weather = {}

-- wttr.in format codes for compact output:
-- %c = weather icon, %C = weather condition, %t = temperature
-- %h = humidity, %w = wind, %p = precipitation, %P = pressure

function Weather.fetch(location)
    location = location or "Alkmaar"

    print("Fetching weather for " .. location .. "...")

    -- Use compact format (one line)
    local url = "https://wttr.in/" .. location .. "?format=%c+%C:+%t+(%h+humidity)+Wind:+%w"

    local resp = ez.http.fetch(url, {
        timeout = 15000,
        headers = {
            ["User-Agent"] = "curl/7.0"  -- wttr.in needs a curl-like user agent
        }
    })

    if resp.ok then
        -- Clean up the response (remove extra whitespace)
        local weather = resp.body:gsub("^%s+", ""):gsub("%s+$", "")
        print("")
        print(weather)
        print("")
    else
        print("Error: " .. (resp.error or "Unknown error"))
        return
    end

    -- Also fetch a more detailed forecast
    print("3-day forecast:")
    print("")

    local detail_url = "https://wttr.in/" .. location .. "?format=%l:\\n%c+%C\\nTemp:+%t+(feels+%f)\\nWind:+%w\\nHumidity:+%h\\n"

    local detail_resp = ez.http.fetch(detail_url, {
        timeout = 15000,
        headers = {
            ["User-Agent"] = "curl/7.0"
        }
    })

    if detail_resp.ok then
        -- Print each line
        for line in detail_resp.body:gmatch("[^\\n]+") do
            local clean = line:gsub("^%s+", ""):gsub("%s+$", "")
            if clean ~= "" then
                print(clean)
            end
        end
    else
        print("Could not fetch detailed forecast")
    end
end

-- Main entry point for spawn_module
function Weather.main(location)
    Weather.fetch(location)
end

-- If run directly (e.g., from terminal), execute immediately
-- The terminal wraps scripts in spawn(), so async works
Weather.fetch()

return Weather
