-- Contacts service
-- Manages contact list with persistence.

local contacts = {}

local PREF_KEY = "contacts_v1"
local MAX_CONTACTS = 64

-- State
local store = {}       -- { [pub_key_hex] = { name, pub_key_hex, path_hash, notes, added_at } }
local initialized = false

-- Compute path_hash from pub_key_hex (first byte of the public key)
local function hash_from_hex(hex)
    if not hex or #hex < 2 then return 0 end
    return tonumber(hex:sub(1, 2), 16) or 0
end

-- Persistence: save to prefs as "hex|name|notes|ack;hex|name|notes|ack;..."
local function save()
    local parts = {}
    for _, c in pairs(store) do
        local name = (c.name or ""):gsub("|", "")
        local notes = (c.notes or ""):gsub("|", "")
        local ack = c.ack_enabled and "1" or "0"
        parts[#parts + 1] = c.pub_key_hex .. "|" .. name .. "|" .. notes .. "|" .. ack
    end
    ez.storage.set_pref(PREF_KEY, table.concat(parts, ";"))
end

local function load_saved()
    local raw = ez.storage.get_pref(PREF_KEY, "")
    if raw == "" then return end
    for entry in raw:gmatch("[^;]+") do
        local hex, name, notes, ack_str = entry:match("^([^|]+)|([^|]*)|([^|]*)|?(.-)$")
        if hex and #hex == 64 then
            store[hex] = {
                pub_key_hex = hex,
                name = name or hex:sub(1, 8),
                path_hash = hash_from_hex(hex),
                notes = notes or "",
                ack_enabled = ack_str == "1" or nil,
                added_at = 0,
            }
        end
    end
end

-- =========================================================================
-- Public API
-- =========================================================================

function contacts.init()
    if initialized then return end
    initialized = true
    load_saved()
    ez.log("[Contacts] Loaded " .. contacts.count() .. " contact(s)")
end

function contacts.add(pub_key_hex, name, notes)
    if not pub_key_hex or #pub_key_hex ~= 64 then return false end
    if contacts.count() >= MAX_CONTACTS and not store[pub_key_hex] then
        return false
    end

    store[pub_key_hex] = {
        pub_key_hex = pub_key_hex,
        name = name or pub_key_hex:sub(1, 8),
        path_hash = hash_from_hex(pub_key_hex),
        notes = notes or "",
        ack_enabled = nil,
        added_at = ez.system.get_time_unix() or 0,
    }
    save()
    ez.bus.post("contacts/changed", pub_key_hex)
    return true
end

function contacts.remove(pub_key_hex)
    if not store[pub_key_hex] then return false end
    store[pub_key_hex] = nil
    save()
    ez.bus.post("contacts/changed", pub_key_hex)
    return true
end

function contacts.update(pub_key_hex, fields)
    local c = store[pub_key_hex]
    if not c then return false end
    if fields.name then c.name = fields.name end
    if fields.notes then c.notes = fields.notes end
    if fields.ack_enabled ~= nil then c.ack_enabled = fields.ack_enabled end
    save()
    ez.bus.post("contacts/changed", pub_key_hex)
    return true
end

function contacts.set_ack_enabled(pub_key_hex, enabled)
    local c = store[pub_key_hex]
    if not c then return false end
    if c.ack_enabled == enabled then return true end
    c.ack_enabled = enabled
    save()
    return true
end

function contacts.is_ack_enabled(pub_key_hex)
    local c = store[pub_key_hex]
    if not c then return nil end
    return c.ack_enabled
end

function contacts.get(pub_key_hex)
    return store[pub_key_hex]
end

function contacts.is_contact(pub_key_hex)
    return store[pub_key_hex] ~= nil
end

function contacts.find_by_hash(path_hash)
    local results = {}
    for _, c in pairs(store) do
        if c.path_hash == path_hash then
            results[#results + 1] = c
        end
    end
    return results
end

function contacts.get_all()
    local list = {}
    for _, c in pairs(store) do
        list[#list + 1] = c
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

function contacts.count()
    local n = 0
    for _ in pairs(store) do n = n + 1 end
    return n
end

return contacts
