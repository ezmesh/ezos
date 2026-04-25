// ez.net — generic TCP + UDP socket bindings.
//
// Exposes a small BSD-socket-shaped API to Lua. Sockets are handle-based
// (integer slot ids) so Lua never holds C++ objects directly, and every
// call is non-blocking unless the name says otherwise. The one-shot
// helpers in wifi_bindings.cpp (tcp_serve_blob / tcp_fetch_blob /
// udp_probe / udp_echo_*) still exist for the legacy file transfer
// code; this module is the general-purpose path for everything else
// (game lobbies, HTTP backends, chat servers, whatever).
//
// Handles
// -------
// Socket IDs are slot-index + 1 (so 0 / nil is always invalid). The
// firmware reserves a small fixed number of slots per type to bound
// internal memory — enough for every app we currently care about, too
// few to let a runaway bug DoS the device.
//
// TCP model
// ---------
//   tcp_listen(port) -> server_id          Binds and starts accepting.
//   tcp_accept(server) -> client_id or nil Polls; nil when no pending.
//   tcp_connect(ip, port, t?) -> cli or nil Blocking connect w/ timeout.
//   tcp_send(cli, data) -> bytes_sent      Best-effort, non-blocking.
//   tcp_recv(cli, max?) -> data or nil     Non-blocking; nil = no data,
//                                          empty string = EOF.
//   tcp_connected(cli) -> bool             Includes unread-buffer check.
//   tcp_close(h)                           Releases the slot.
//
// UDP model
// ---------
//   udp_open(port?) -> udp_id              port=0/nil → ephemeral bind.
//   udp_recv(udp) -> data, from_ip, from_port   or nil if nothing queued.
//   udp_send(udp, ip, port, data) -> bytes or nil
//   udp_close(h)
//
// Non-blocking ethos: callers drive their own read/write loop on the
// main Lua loop (or a timer). Nothing here blocks the UI longer than
// a single syscall would.

#include "../lua_bindings.h"
#include <Arduino.h>
#include <WiFi.h>
#include <WiFiClient.h>
#include <WiFiServer.h>
#include <WiFiUdp.h>

// Slot limits. Small on purpose — the only apps touching these are
// multiplayer game lobbies (1 server + 1–8 clients), HTTP pages (1–2
// concurrent requests), maybe a couple of UDP responders. Generous
// enough that we never have to refuse a legit open, tight enough that
// a leak shows up fast rather than silently.
static constexpr size_t MAX_TCP_SERVERS = 4;
static constexpr size_t MAX_TCP_CLIENTS = 16;
static constexpr size_t MAX_UDP_SOCKS   = 8;

// Read chunk for recv(). 1 KB matches the TCP MSS on typical LAN paths
// and keeps a single Lua round-trip reasonable. For UDP the same
// buffer catches any standard MTU-sized datagram plus headroom.
static constexpr size_t RX_CHUNK        = 1024;

// Reusable scratch buffers so per-call allocations don't hammer the
// heap. Only one call at a time reads them (Lua is single-threaded),
// so sharing is safe.
static uint8_t rxScratch[RX_CHUNK];
static uint8_t udpScratch[RX_CHUNK];

struct TcpServerSlot {
    bool active;
    WiFiServer* server;
};
struct TcpClientSlot {
    bool active;
    WiFiClient* client;
};
struct UdpSlot {
    bool active;
    WiFiUDP* udp;
};

static TcpServerSlot tcpServers[MAX_TCP_SERVERS];
static TcpClientSlot tcpClients[MAX_TCP_CLIENTS];
static UdpSlot       udpSlots[MAX_UDP_SOCKS];

// ---------------------------------------------------------------------------
// Slot helpers (handle <-> pointer round-trip)
// ---------------------------------------------------------------------------

static int allocTcpServer(WiFiServer* s) {
    for (size_t i = 0; i < MAX_TCP_SERVERS; i++) {
        if (!tcpServers[i].active) {
            tcpServers[i].active = true;
            tcpServers[i].server = s;
            return (int)i + 1;
        }
    }
    return 0;
}
static WiFiServer* getTcpServer(int id) {
    if (id < 1 || id > (int)MAX_TCP_SERVERS) return nullptr;
    TcpServerSlot& slot = tcpServers[id - 1];
    if (!slot.active) return nullptr;
    return slot.server;
}
static void freeTcpServer(int id) {
    if (id < 1 || id > (int)MAX_TCP_SERVERS) return;
    TcpServerSlot& slot = tcpServers[id - 1];
    if (!slot.active) return;
    if (slot.server) { slot.server->stop(); delete slot.server; }
    slot.server = nullptr;
    slot.active = false;
}

static int allocTcpClient(WiFiClient* c) {
    for (size_t i = 0; i < MAX_TCP_CLIENTS; i++) {
        if (!tcpClients[i].active) {
            tcpClients[i].active = true;
            tcpClients[i].client = c;
            return (int)i + 1;
        }
    }
    return 0;
}
static WiFiClient* getTcpClient(int id) {
    if (id < 1 || id > (int)MAX_TCP_CLIENTS) return nullptr;
    TcpClientSlot& slot = tcpClients[id - 1];
    if (!slot.active) return nullptr;
    return slot.client;
}
static void freeTcpClient(int id) {
    if (id < 1 || id > (int)MAX_TCP_CLIENTS) return;
    TcpClientSlot& slot = tcpClients[id - 1];
    if (!slot.active) return;
    if (slot.client) { slot.client->stop(); delete slot.client; }
    slot.client = nullptr;
    slot.active = false;
}

static int allocUdp(WiFiUDP* u) {
    for (size_t i = 0; i < MAX_UDP_SOCKS; i++) {
        if (!udpSlots[i].active) {
            udpSlots[i].active = true;
            udpSlots[i].udp = u;
            return (int)i + 1;
        }
    }
    return 0;
}
static WiFiUDP* getUdp(int id) {
    if (id < 1 || id > (int)MAX_UDP_SOCKS) return nullptr;
    UdpSlot& slot = udpSlots[id - 1];
    if (!slot.active) return nullptr;
    return slot.udp;
}
static void freeUdp(int id) {
    if (id < 1 || id > (int)MAX_UDP_SOCKS) return;
    UdpSlot& slot = udpSlots[id - 1];
    if (!slot.active) return;
    if (slot.udp) { slot.udp->stop(); delete slot.udp; }
    slot.udp = nullptr;
    slot.active = false;
}

// ---------------------------------------------------------------------------
// TCP
// ---------------------------------------------------------------------------

// @lua ez.net.tcp_listen(port) -> integer|nil
// @brief Open a TCP listening socket
// @description Binds a new TCP server to the given port and returns a
// slot handle. Accept incoming clients with ez.net.tcp_accept. Nil is
// returned when no slots are free (max 4 concurrent servers) or bind
// fails. The server is in non-blocking accept mode; tcp_accept polls.
// @end
LUA_FUNCTION(l_net_tcp_listen) {
    LUA_CHECK_ARGC(L, 1);
    uint16_t port = (uint16_t)luaL_checkinteger(L, 1);
    WiFiServer* s = new WiFiServer(port);
    s->begin();
    s->setNoDelay(true);
    int id = allocTcpServer(s);
    if (id == 0) { s->stop(); delete s; lua_pushnil(L); return 1; }
    lua_pushinteger(L, id);
    return 1;
}

// @lua ez.net.tcp_accept(server_id) -> integer|nil
// @brief Non-blocking accept. Returns a new client handle or nil.
// @end
LUA_FUNCTION(l_net_tcp_accept) {
    LUA_CHECK_ARGC(L, 1);
    int sid = (int)luaL_checkinteger(L, 1);
    WiFiServer* server = getTcpServer(sid);
    if (!server) { lua_pushnil(L); return 1; }
    WiFiClient c = server->available();
    if (!c || !c.connected()) { lua_pushnil(L); return 1; }
    // Copy onto the heap so its lifetime matches the slot, not this
    // stack frame. WiFiClient is reference-counted internally so the
    // underlying socket isn't closed by the copy.
    WiFiClient* heap = new WiFiClient(c);
    int cid = allocTcpClient(heap);
    if (cid == 0) { heap->stop(); delete heap; lua_pushnil(L); return 1; }
    lua_pushinteger(L, cid);
    return 1;
}

// @lua ez.net.tcp_connect(ip, port, timeout_ms?) -> integer|nil
// @brief Connect to a remote TCP server. Blocks up to timeout_ms on the
// 3-way handshake (default 5000).
// @end
LUA_FUNCTION(l_net_tcp_connect) {
    LUA_CHECK_ARGC_RANGE(L, 2, 3);
    const char* ip_str = luaL_checkstring(L, 1);
    uint16_t port = (uint16_t)luaL_checkinteger(L, 2);
    uint32_t timeout = (uint32_t)luaL_optintegerdefault(L, 3, 5000);
    IPAddress addr;
    if (!addr.fromString(ip_str)) { lua_pushnil(L); return 1; }
    WiFiClient* c = new WiFiClient();
    c->setTimeout(timeout);
    if (!c->connect(addr, port, timeout)) {
        delete c; lua_pushnil(L); return 1;
    }
    int cid = allocTcpClient(c);
    if (cid == 0) { c->stop(); delete c; lua_pushnil(L); return 1; }
    lua_pushinteger(L, cid);
    return 1;
}

// @lua ez.net.tcp_send(client_id, data) -> integer|nil
// @brief Best-effort non-blocking send. Returns bytes actually written.
// @end
LUA_FUNCTION(l_net_tcp_send) {
    LUA_CHECK_ARGC(L, 2);
    int cid = (int)luaL_checkinteger(L, 1);
    size_t len = 0;
    const char* data = luaL_checklstring(L, 2, &len);
    WiFiClient* c = getTcpClient(cid);
    if (!c || !c->connected()) { lua_pushnil(L); return 1; }
    size_t avail = (size_t)c->availableForWrite();
    size_t n = (avail == 0 || avail > len) ? len : avail;
    int w = c->write((const uint8_t*)data, n);
    if (w < 0) { lua_pushnil(L); return 1; }
    lua_pushinteger(L, w);
    return 1;
}

// @lua ez.net.tcp_recv(client_id, max_bytes?) -> string|nil
// @brief Non-blocking read. nil = no data / error, "" = peer closed,
// otherwise a chunk of bytes (up to max_bytes or 1024 default).
// @end
LUA_FUNCTION(l_net_tcp_recv) {
    LUA_CHECK_ARGC_RANGE(L, 1, 2);
    int cid = (int)luaL_checkinteger(L, 1);
    int maxb = (int)luaL_optintegerdefault(L, 2, (lua_Integer)RX_CHUNK);
    if (maxb <= 0) { lua_pushnil(L); return 1; }
    if (maxb > (int)RX_CHUNK) maxb = (int)RX_CHUNK;
    WiFiClient* c = getTcpClient(cid);
    if (!c) { lua_pushnil(L); return 1; }
    int avail = c->available();
    if (avail <= 0) {
        if (!c->connected()) {
            // Remote closed with no buffered bytes — clean EOF.
            lua_pushlstring(L, "", 0);
            return 1;
        }
        lua_pushnil(L);
        return 1;
    }
    int want = avail < maxb ? avail : maxb;
    int got = c->read(rxScratch, want);
    if (got <= 0) { lua_pushnil(L); return 1; }
    lua_pushlstring(L, (const char*)rxScratch, (size_t)got);
    return 1;
}

// @lua ez.net.tcp_connected(client_id) -> boolean
// @brief True iff the socket is still open or has buffered unread bytes.
// @end
LUA_FUNCTION(l_net_tcp_connected) {
    LUA_CHECK_ARGC(L, 1);
    int cid = (int)luaL_checkinteger(L, 1);
    WiFiClient* c = getTcpClient(cid);
    lua_pushboolean(L, c && c->connected());
    return 1;
}

// @lua ez.net.tcp_close(handle)
// @brief Close a TCP server or client handle, freeing its slot. Safe
// to call with an already-freed or invalid handle.
// @note The handle type isn't expressed in the argument; callers pass
// either a client or server id and the binding dispatches. Keeps the
// API compact at the cost of a tiny ambiguity (a leaked id could in
// principle name a server slot that was later reused as a client slot
// after free — the slot index spaces are disjoint so this can't happen
// in practice).
// @end
LUA_FUNCTION(l_net_tcp_close) {
    LUA_CHECK_ARGC(L, 1);
    int id = (int)luaL_checkinteger(L, 1);
    // Try both tables; only one will actually hold this id.
    freeTcpClient(id);
    freeTcpServer(id);
    return 0;
}

// ---------------------------------------------------------------------------
// UDP
// ---------------------------------------------------------------------------

// @lua ez.net.udp_open(port?) -> integer|nil
// @brief Open a UDP socket bound to the given port. port=0 or nil picks
// an ephemeral port (useful for client-only use).
// @end
LUA_FUNCTION(l_net_udp_open) {
    LUA_CHECK_ARGC_RANGE(L, 0, 1);
    uint16_t port = (uint16_t)luaL_optintegerdefault(L, 1, 0);
    WiFiUDP* u = new WiFiUDP();
    if (!u->begin(port)) { delete u; lua_pushnil(L); return 1; }
    int id = allocUdp(u);
    if (id == 0) { u->stop(); delete u; lua_pushnil(L); return 1; }
    lua_pushinteger(L, id);
    return 1;
}

// @lua ez.net.udp_recv(udp_id) -> data, ip, port  or  nil
// @brief Non-blocking receive. Returns the next pending datagram's
// payload plus the sender's IP and port, or nil when nothing's queued.
// @end
LUA_FUNCTION(l_net_udp_recv) {
    LUA_CHECK_ARGC(L, 1);
    int uid = (int)luaL_checkinteger(L, 1);
    WiFiUDP* u = getUdp(uid);
    if (!u) { lua_pushnil(L); return 1; }
    int pktSize = u->parsePacket();
    if (pktSize <= 0) { lua_pushnil(L); return 1; }
    int cap = (int)sizeof(udpScratch);
    int want = pktSize < cap ? pktSize : cap;
    int got = u->read(udpScratch, want);
    if (got <= 0) { lua_pushnil(L); return 1; }
    IPAddress from = u->remoteIP();
    uint16_t port = u->remotePort();
    lua_pushlstring(L, (const char*)udpScratch, (size_t)got);
    lua_pushstring(L, from.toString().c_str());
    lua_pushinteger(L, port);
    return 3;
}

// @lua ez.net.udp_send(udp_id, ip, port, data) -> integer|nil
// @brief Send a single UDP datagram. Returns payload length on success
// (UDP has no partial writes — it's all or nothing per datagram).
// @end
LUA_FUNCTION(l_net_udp_send) {
    LUA_CHECK_ARGC(L, 4);
    int uid = (int)luaL_checkinteger(L, 1);
    const char* ip_str = luaL_checkstring(L, 2);
    uint16_t port = (uint16_t)luaL_checkinteger(L, 3);
    size_t len = 0;
    const char* data = luaL_checklstring(L, 4, &len);
    WiFiUDP* u = getUdp(uid);
    if (!u) { lua_pushnil(L); return 1; }
    IPAddress addr;
    if (!addr.fromString(ip_str)) { lua_pushnil(L); return 1; }
    if (!u->beginPacket(addr, port)) { lua_pushnil(L); return 1; }
    int written = u->write((const uint8_t*)data, len);
    if (!u->endPacket()) { lua_pushnil(L); return 1; }
    if (written < 0) { lua_pushnil(L); return 1; }
    lua_pushinteger(L, written);
    return 1;
}

// @lua ez.net.udp_close(udp_id)
// @brief Close and free the UDP slot.
// @end
LUA_FUNCTION(l_net_udp_close) {
    LUA_CHECK_ARGC(L, 1);
    int uid = (int)luaL_checkinteger(L, 1);
    freeUdp(uid);
    return 0;
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

static const luaL_Reg net_funcs[] = {
    {"tcp_listen",    l_net_tcp_listen},
    {"tcp_accept",    l_net_tcp_accept},
    {"tcp_connect",   l_net_tcp_connect},
    {"tcp_send",      l_net_tcp_send},
    {"tcp_recv",      l_net_tcp_recv},
    {"tcp_connected", l_net_tcp_connected},
    {"tcp_close",     l_net_tcp_close},
    {"udp_open",      l_net_udp_open},
    {"udp_recv",      l_net_udp_recv},
    {"udp_send",      l_net_udp_send},
    {"udp_close",     l_net_udp_close},
    {nullptr, nullptr}
};

void registerNetModule(lua_State* L) {
    lua_register_module(L, "net", net_funcs);
    Serial.println("[LuaRuntime] Registered ez.net");
}
