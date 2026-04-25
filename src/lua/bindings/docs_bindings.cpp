// ez.docs module bindings
// Reads markdown documentation embedded in firmware via
// scripts/embed_lua_scripts.py (DOC_SOURCE_DIR = lua/docs/). The Help screen
// uses this to render the on-device user manual without touching LittleFS or
// the SD card.
//
// Doc paths use a leading "@" sentinel (e.g. "@manual/getting-started.md") so
// they cannot be confused with embedded Lua scripts (which use "$") or
// LittleFS / SD paths (which use "/fs/" / "/sd/").

#include "../lua_bindings.h"
#include "../embedded_docs.h"

// ez.docs.list() -> { string, ... }
// @brief List the virtual paths of every embedded markdown doc.
// @description
//   Each entry is a virtual path beginning with "@" — pass it back to
//   ez.docs.read to get the markdown bytes. Empty when no docs are
//   embedded (e.g. a build that hasn't created lua/docs/).
// @return Array of doc path strings.
// @example
//   for _, p in ipairs(ez.docs.list()) do print(p) end
// @end
LUA_FUNCTION(l_docs_list) {
    size_t n = embedded_docs::get_doc_count();
    lua_createtable(L, (int)n, 0);
    for (size_t i = 0; i < n; i++) {
        const char* path = embedded_docs::get_doc_path(i);
        if (!path) continue;
        lua_pushstring(L, path);
        lua_rawseti(L, -2, (int)(i + 1));
    }
    return 1;
}

// ez.docs.read(path) -> string | nil
// @brief Read an embedded markdown doc by virtual path.
// @description
//   Returns the raw markdown bytes for `path` (an "@..."-prefixed string
//   from ez.docs.list), or nil if no such doc is embedded.
// @param path Virtual doc path (e.g. "@manual/getting-started.md").
// @return Markdown source as a string, or nil when not found.
// @example
//   local md = ez.docs.read("@manual/getting-started.md")
//   if md then print(md) end
// @end
LUA_FUNCTION(l_docs_read) {
    const char* path = luaL_checkstring(L, 1);
    size_t size = 0;
    const char* data = embedded_docs::get_doc(path, &size);
    if (!data) {
        lua_pushnil(L);
        return 1;
    }
    lua_pushlstring(L, data, size);
    return 1;
}

static const luaL_Reg docs_funcs[] = {
    {"list", l_docs_list},
    {"read", l_docs_read},
    {nullptr, nullptr},
};

void registerDocsModule(lua_State* L) {
    lua_register_module(L, "docs", docs_funcs);
    Serial.println("[LuaRuntime] Registered ez.docs");
}
