-- Contacts service
-- Handles saved contacts, discovered node cache, and auto time sync from trusted contacts

local Contacts = {
    -- Saved contacts (user-added): { pub_key_hex = { name, path_hash, notes, added_time } }
    saved = {},
    -- Discovered node cache: { pub_key_hex = { name, path_hash, last_seen, rssi, role, advert_timestamp, lat, lon, has_location } }
    discovered = {},
    -- Settings
    auto_time_sync = true,  -- Sync time from trusted contacts when time is unset
    -- Constants
    MAX_DISCOVERED = 100,   -- Max cached discovered nodes
    CACHE_EXPIRE_DAYS = 7,  -- Remove discovered nodes not seen for this many days
}

-- Storage path (prefer SD card for more space)
local function get_storage_path()
    if ez.storage.is_sd_available() then
        -- Ensure directory exists
        if not ez.storage.exists("/sd/data") then
            ez.storage.mkdir("/sd/data")
        end
        return "/sd/data/contacts.json"
    end
    return "/contacts.json"
end

-- Initialize the contacts service
function Contacts.init()
    -- Load saved data
    Contacts._load()

    -- Load auto time sync setting
    local auto_sync = ez.storage.get_pref("autoTimeSyncContacts", "true")
    Contacts.auto_time_sync = (auto_sync == "true" or auto_sync == true)

    -- Subscribe to node discovery events via message bus
    if ez.bus and ez.bus.subscribe then
        ez.bus.subscribe("mesh/node_discovered", function(topic, node)
            -- node is a table with path_hash, name, rssi, snr, pub_key_hex, etc.
            Contacts._handle_node_discovered(node)
        end)
    end

    ez.system.log("[Contacts] Initialized: " .. Contacts._count_saved() .. " saved, " ..
          Contacts._count_discovered() .. " cached")
end

-- Check if a node is a saved contact
-- @param pub_key_hex Public key as hex string
-- @return contact info or nil
function Contacts.is_saved(pub_key_hex)
    return Contacts.saved[pub_key_hex]
end

-- Check if a node is saved by path hash (less reliable but useful)
-- @param path_hash Path hash byte
-- @return contact info or nil
function Contacts.is_saved_by_hash(path_hash)
    for pub_key, contact in pairs(Contacts.saved) do
        if contact.path_hash == path_hash then
            return contact, pub_key
        end
    end
    return nil
end

-- Add a contact
-- @param node Node info from mesh (must have pub_key or pub_key_hex)
-- @param notes Optional notes
-- @return true if added
function Contacts.add(node, notes)
    local pub_key_hex = node.pub_key_hex
    if not pub_key_hex and node.pub_key then
        -- Convert binary to hex
        pub_key_hex = ""
        for i = 1, #node.pub_key do
            pub_key_hex = pub_key_hex .. string.format("%02X", string.byte(node.pub_key, i))
        end
    end

    if not pub_key_hex or #pub_key_hex < 64 then
        ez.system.log("[Contacts] Cannot add contact: no valid public key")
        return false
    end

    Contacts.saved[pub_key_hex] = {
        name = node.name or "Unknown",
        path_hash = node.path_hash,
        notes = notes or "",
        added_time = ez.system.get_time_unix() or 0,
    }

    Contacts._save()
    ez.system.log("[Contacts] Added contact: " .. (node.name or pub_key_hex:sub(1, 8)))
    return true
end

-- Remove a contact
-- @param pub_key_hex Public key as hex string
-- @return true if removed
function Contacts.remove(pub_key_hex)
    if Contacts.saved[pub_key_hex] then
        local name = Contacts.saved[pub_key_hex].name
        Contacts.saved[pub_key_hex] = nil
        Contacts._save()
        ez.system.log("[Contacts] Removed contact: " .. name)
        return true
    end
    return false
end

-- Get all saved contacts
-- @return array of { pub_key_hex, name, path_hash, notes, added_time }
function Contacts.get_saved()
    local result = {}
    for pub_key_hex, info in pairs(Contacts.saved) do
        table.insert(result, {
            pub_key_hex = pub_key_hex,
            name = info.name,
            path_hash = info.path_hash,
            notes = info.notes,
            added_time = info.added_time,
        })
    end
    -- Sort by name
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

-- Get all discovered nodes (merged with live mesh data)
-- @return array of node info
function Contacts.get_discovered()
    local result = {}
    local dominated = {}  -- Track which discovered entries are superseded by live data

    -- First, get live nodes from mesh
    local live_nodes = {}
    if ez.mesh.is_initialized() then
        live_nodes = ez.mesh.get_nodes() or {}
    end

    -- Add live nodes, marking their pub keys as dominated
    for _, node in ipairs(live_nodes) do
        local pub_key_hex = node.pub_key_hex
        if pub_key_hex then
            dominated[pub_key_hex] = true
        end

        -- Enrich with saved contact info
        local saved = pub_key_hex and Contacts.saved[pub_key_hex]
        if saved then
            node.is_saved = true
            node.notes = saved.notes
        end

        table.insert(result, node)
    end

    -- Add cached discovered nodes that aren't in live data
    for pub_key_hex, cached in pairs(Contacts.discovered) do
        if not dominated[pub_key_hex] then
            -- Check if still valid (not expired)
            local age_days = 0
            if cached.last_seen and cached.last_seen > 0 then
                local now = ez.system.millis()
                age_days = (now - cached.last_seen) / (1000 * 86400)
            end

            if age_days < Contacts.CACHE_EXPIRE_DAYS then
                local node = {
                    name = cached.name,
                    path_hash = cached.path_hash,
                    pub_key_hex = pub_key_hex,
                    last_seen = cached.last_seen,
                    rssi = cached.rssi,
                    role = cached.role,
                    advert_timestamp = cached.advert_timestamp,
                    is_cached = true,  -- Mark as from cache, not live
                    has_location = cached.has_location,
                    lat = cached.lat,
                    lon = cached.lon,
                }

                -- Enrich with saved contact info
                local saved = Contacts.saved[pub_key_hex]
                if saved then
                    node.is_saved = true
                    node.notes = saved.notes
                end

                table.insert(result, node)
            end
        end
    end

    -- Sort by last seen (most recent first)
    table.sort(result, function(a, b)
        return (a.last_seen or 0) > (b.last_seen or 0)
    end)

    return result
end

-- Handle discovered node (from on_node_discovered callback)
function Contacts._handle_node_discovered(node)
    local pub_key_hex = node.pub_key_hex
    if not pub_key_hex then return end

    -- Update discovered cache
    Contacts.discovered[pub_key_hex] = {
        name = node.name or "Unknown",
        path_hash = node.path_hash,
        last_seen = ez.system.millis(),
        rssi = node.rssi,
        role = node.role,
        advert_timestamp = node.advert_timestamp,
        has_location = node.has_location or false,
        lat = node.lat,
        lon = node.lon,
    }

    -- Trim cache if too large
    Contacts._trim_discovered()

    -- Auto time sync from trusted contacts
    if Contacts.auto_time_sync then
        Contacts._check_auto_time_sync(node)
    end

    -- Publish node count change event for status bar
    if ez.bus and ez.bus.post then
        local count = Contacts._count_discovered()
        ez.bus.post("mesh/node_count", tostring(count))
    end
end

-- Check if we should auto-sync time from this contact's ADVERT
function Contacts._check_auto_time_sync(node)
    -- Only sync if time is not set
    local current_time = ez.system.get_time_unix()
    if current_time and current_time > 1577836800 then
        -- Time already set (after 2020)
        return
    end

    -- Only sync from saved contacts
    local pub_key_hex = node.pub_key_hex
    if not pub_key_hex or not Contacts.saved[pub_key_hex] then
        return
    end

    -- Check if node has valid timestamp from their ADVERT
    local ts = node.advert_timestamp
    if not ts or ts < 1577836800 or ts > 4102444800 then
        return
    end

    -- Calculate corrected time (add age since we received this ADVERT)
    local age_seconds = node.age_seconds or 0
    local corrected_time = ts + age_seconds

    -- Set the time
    local ok = ez.system.set_time_unix(corrected_time)
    if ok then
        local contact_name = Contacts.saved[pub_key_hex].name
        ez.system.log("[Contacts] Auto time sync from " .. contact_name)
        ez.storage.set_pref("lastTimeSet", corrected_time)
    end
end

-- Trim discovered cache to max size
function Contacts._trim_discovered()
    local count = 0
    for _ in pairs(Contacts.discovered) do
        count = count + 1
    end

    if count <= Contacts.MAX_DISCOVERED then
        return
    end

    -- Convert to array and sort by last_seen
    local entries = {}
    for pub_key, info in pairs(Contacts.discovered) do
        table.insert(entries, { pub_key = pub_key, last_seen = info.last_seen or 0 })
    end
    table.sort(entries, function(a, b) return a.last_seen < b.last_seen end)

    -- Remove oldest entries
    local to_remove = count - Contacts.MAX_DISCOVERED
    for i = 1, to_remove do
        Contacts.discovered[entries[i].pub_key] = nil
    end
end

-- Count saved contacts
function Contacts._count_saved()
    local count = 0
    for _ in pairs(Contacts.saved) do
        count = count + 1
    end
    return count
end

-- Count discovered nodes
function Contacts._count_discovered()
    local count = 0
    for _ in pairs(Contacts.discovered) do
        count = count + 1
    end
    return count
end

-- Save to storage
function Contacts._save()
    local data = {
        version = 1,
        saved = {},
    }

    -- Save contacts only (discovered nodes are not persisted)
    for pub_key_hex, info in pairs(Contacts.saved) do
        table.insert(data.saved, {
            pub_key = pub_key_hex,
            name = info.name,
            path_hash = info.path_hash,
            notes = info.notes,
            added_time = info.added_time,
        })
    end

    local json = ez.storage.json_encode(data)
    if json then
        local path = get_storage_path()
        local ok = ez.storage.write(path, json)
        if not ok then
            -- Fallback to flash if SD write failed
            ez.storage.write("/contacts.json", json)
        end
    end
end

-- Load from storage
function Contacts._load()
    -- Try SD first, then flash
    local json = nil
    if ez.storage.is_sd_available() then
        json = ez.storage.read("/sd/data/contacts.json")
    end
    if not json then
        json = ez.storage.read("/contacts.json")
    end

    if not json then
        return
    end

    local data = ez.storage.json_decode(json)
    if not data or data.version ~= 1 then
        return
    end

    -- Load saved contacts only (discovered nodes are not persisted)
    Contacts.saved = {}
    for _, contact in ipairs(data.saved or {}) do
        if contact.pub_key then
            Contacts.saved[contact.pub_key] = {
                name = contact.name or "Unknown",
                path_hash = contact.path_hash,
                notes = contact.notes or "",
                added_time = contact.added_time or 0,
            }
        end
    end

    -- Discovered nodes start empty (populated at runtime from mesh)
    Contacts.discovered = {}
end

-- Set auto time sync setting
function Contacts.set_auto_time_sync(enabled)
    Contacts.auto_time_sync = enabled
    ez.storage.set_pref("autoTimeSyncContacts", enabled and "true" or "false")
end

-- Clear discovered node cache (keeps saved contacts)
function Contacts.clear_discovered()
    Contacts.discovered = {}
    ez.system.log("[Contacts] Discovered node cache cleared")
end

return Contacts
