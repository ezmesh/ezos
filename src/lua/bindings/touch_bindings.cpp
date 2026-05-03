// ez.touch module bindings
//
// Wraps the GT911 capacitive driver. Two ways to consume input:
//
//   1) Pull model -- ez.touch.read() returns the array of points
//      currently down. Useful for a per-frame redraw loop that wants
//      a snapshot.
//
//   2) Push model -- subscribe to the bus topics:
//        touch/down { id, x, y, size }
//        touch/move { id, x, y, size }
//        touch/up   { id, x, y }
//      ez.touch.update() (called by the main loop) tracks the prior
//      frame's points and synthesises down/move/up so consumers don't
//      have to diff snapshots themselves.
//
// All coordinates are in raw panel pixels (0..319 X, 0..239 Y) before
// any rotation is applied. Display rotation is a Lua-side concern.

#include "touch_bindings.h"
#include "../lua_bindings.h"
#include "../../hardware/touch.h"
#include "bus_bindings.h"

#include <Arduino.h>
#include <string.h>

// @module ez.touch
// @brief Capacitive touchscreen access (GT911 on T-Deck Plus)
// @description
// Reports active contact points and dispatches touch/down, touch/move,
// and touch/up events on the global message bus. Up to 5 simultaneous
// points are supported. The hardware is the Goodix GT911 sitting on
// the same I2C bus as the keyboard at address 0x5D.
// @end

// External global, defined in main.cpp
extern Touch* touch;

namespace {
    // Per-track state from the previous update() poll. The GT911
    // assigns a stable track id (0..15) to a contact for the duration
    // of the touch, so we use that as the dictionary key. -1 means
    // "no contact tracked in this slot".
    struct TrackState {
        int      id   = -1;
        uint16_t x    = 0;
        uint16_t y    = 0;
        uint16_t size = 0;
    };
    constexpr size_t MAX_TRACKED = 8;   // a few more than the panel's 5
    TrackState g_prev[MAX_TRACKED];

    void postPoint(const char* topic, const Touch::Point& p) {
        MessageBus::instance().postTable(topic, [p](lua_State* L) {
            lua_createtable(L, 0, 4);
            lua_pushinteger(L, p.id);
            lua_setfield(L, -2, "id");
            lua_pushinteger(L, p.x);
            lua_setfield(L, -2, "x");
            lua_pushinteger(L, p.y);
            lua_setfield(L, -2, "y");
            lua_pushinteger(L, p.size);
            lua_setfield(L, -2, "size");
        });
    }

    void postUp(int id, uint16_t x, uint16_t y) {
        MessageBus::instance().postTable("touch/up", [id, x, y](lua_State* L) {
            lua_createtable(L, 0, 3);
            lua_pushinteger(L, id);
            lua_setfield(L, -2, "id");
            lua_pushinteger(L, x);
            lua_setfield(L, -2, "x");
            lua_pushinteger(L, y);
            lua_setfield(L, -2, "y");
        });
    }
}

namespace touch_bindings {

void update() {
    if (touch == nullptr || !touch->ready()) return;

    // Only act on frames where the GT911 says "fresh sample
    // available" -- read() returns -1 in any other case. Without
    // this, polls between the controller's sample commits would
    // process zero points and emit phantom touch/up events while a
    // finger was still pressed, chopping a single drag into a long
    // sequence of rapid down/up pairs.
    Touch::Point pts[Touch::MAX_POINTS];
    int n = touch->read(pts);
    if (n < 0) return;

    // Build a mask of which previous tracks are still alive.
    bool seen[MAX_TRACKED] = {false};

    for (int i = 0; i < n; ++i) {
        const Touch::Point& p = pts[i];

        // Find the slot for this id (existing or new).
        size_t slot = MAX_TRACKED;
        for (size_t s = 0; s < MAX_TRACKED; ++s) {
            if (g_prev[s].id == p.id) { slot = s; break; }
        }
        if (slot == MAX_TRACKED) {
            for (size_t s = 0; s < MAX_TRACKED; ++s) {
                if (g_prev[s].id < 0) { slot = s; break; }
            }
        }
        if (slot == MAX_TRACKED) continue;   // no room; drop the event

        if (g_prev[slot].id != p.id) {
            // New contact -- emit down.
            postPoint("touch/down", p);
        } else if (g_prev[slot].x != p.x || g_prev[slot].y != p.y) {
            // Same finger, moved.
            postPoint("touch/move", p);
        }
        g_prev[slot].id   = p.id;
        g_prev[slot].x    = p.x;
        g_prev[slot].y    = p.y;
        g_prev[slot].size = p.size;
        seen[slot]        = true;
    }

    // Fire touch/up for any track that was active last frame but
    // didn't reappear this frame.
    for (size_t s = 0; s < MAX_TRACKED; ++s) {
        if (g_prev[s].id >= 0 && !seen[s]) {
            postUp(g_prev[s].id, g_prev[s].x, g_prev[s].y);
            g_prev[s].id = -1;
        }
    }
}

}  // namespace touch_bindings

// @lua ez.touch.is_initialized() -> boolean
// @brief True if the GT911 came up at boot
// @description Returns false if the touch controller failed to ACK on
// I2C at startup. The OS still works without touch -- keyboard and
// trackball remain primary inputs -- but ez.touch.read() will always
// return an empty list.
// @return true if touch hardware is ready
// @example
// if not ez.touch.is_initialized() then ez.log("no touch") end
// @end
LUA_FUNCTION(l_touch_is_initialized) {
    lua_pushboolean(L, touch != nullptr && touch->ready());
    return 1;
}

// @lua ez.touch.product_id() -> string
// @brief 4-byte ASCII product id reported by the GT911
// @description Reads the GT911's PRODUCT_ID register (0x8140). On a
// healthy panel this returns "911" -- a different string suggests a
// damaged controller or a non-GT911 part on the same I2C address.
// @return Product id string, or "" if uninitialised
// @example
// print(ez.touch.product_id())   -- "911"
// @end
LUA_FUNCTION(l_touch_product_id) {
    if (touch && touch->ready()) {
        lua_pushstring(L, touch->productId());
    } else {
        lua_pushstring(L, "");
    }
    return 1;
}

// @lua ez.touch.firmware_version() -> integer
// @brief GT911 firmware revision
// @description 16-bit value from register 0x8144. Useful for a
// diagnostics page; not interesting at runtime.
// @return Firmware version, or 0 if uninitialised
// @example
// print(string.format("%04X", ez.touch.firmware_version()))
// @end
LUA_FUNCTION(l_touch_firmware_version) {
    if (touch && touch->ready()) {
        lua_pushinteger(L, touch->firmwareVersion());
    } else {
        lua_pushinteger(L, 0);
    }
    return 1;
}

// @lua ez.touch.read() -> table
// @brief Snapshot of currently-pressed contact points
// @description Polls the GT911 once and returns an array of points,
// each `{ id, x, y, size }`. Returns an empty array when nothing is
// pressed or when touch is unavailable. Coordinates are panel-native
// pixels (0..319 X, 0..239 Y); apply your own rotation if needed.
//
// This is a "pull-style" API. For event-driven use, subscribe to the
// touch/down, touch/move, and touch/up topics on the global bus
// instead -- ez.touch.update() (called by the main loop) synthesises
// those from the same poll.
// @return Array of point tables; #points <= 5
// @example
// local pts = ez.touch.read()
// for _, p in ipairs(pts) do
//   print(p.id, p.x, p.y, p.size)
// end
// @end
LUA_FUNCTION(l_touch_read) {
    if (touch == nullptr || !touch->ready()) {
        lua_createtable(L, 0, 0);
        return 1;
    }
    Touch::Point pts[Touch::MAX_POINTS];
    uint8_t n = touch->read(pts);
    lua_createtable(L, n, 0);
    for (uint8_t i = 0; i < n; ++i) {
        lua_createtable(L, 0, 4);
        lua_pushinteger(L, pts[i].id);   lua_setfield(L, -2, "id");
        lua_pushinteger(L, pts[i].x);    lua_setfield(L, -2, "x");
        lua_pushinteger(L, pts[i].y);    lua_setfield(L, -2, "y");
        lua_pushinteger(L, pts[i].size); lua_setfield(L, -2, "size");
        lua_rawseti(L, -2, i + 1);
    }
    return 1;
}

// @bus touch/down
// @brief Posted when a finger first contacts the panel
// @payload { id: integer, x: integer, y: integer, size: integer }

// @bus touch/move
// @brief Posted when a tracked finger moves
// @payload { id: integer, x: integer, y: integer, size: integer }

// @bus touch/up
// @brief Posted when a finger lifts off the panel
// @payload { id: integer, x: integer, y: integer }

static const luaL_Reg touch_funcs[] = {
    {"is_initialized",   l_touch_is_initialized},
    {"product_id",       l_touch_product_id},
    {"firmware_version", l_touch_firmware_version},
    {"read",             l_touch_read},
    {nullptr, nullptr}
};

namespace touch_bindings {
void registerBindings(lua_State* L) {
    lua_register_module(L, "touch", touch_funcs);
    Serial.println("[LuaRuntime] Registered ez.touch");
}
}
