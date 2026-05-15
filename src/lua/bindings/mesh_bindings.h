// ez.mesh module bindings -- internal interface
//
// Most of the mesh binding surface is registered through
// lua_register_module() in mesh_bindings.cpp. This header exposes the
// few helpers that have to be reachable from outside that translation
// unit -- specifically, the bus-publishing helper for ADVERT discovery
// events, which has to fire from the default C++ setNodeCallback in
// main.cpp so that bus subscribers (services.link_quality,
// services.contacts) receive events regardless of whether Lua ever
// called the deprecated ez.mesh.on_node_discovered binding.

#pragma once

struct NodeInfo;

// Post a "mesh/node_discovered" event to the global MessageBus with
// the full node payload (the same shape pushNodeTable produces inside
// mesh_bindings.cpp). Safe to call from any thread / context that
// MessageBus::postTable supports; it dispatches on the Lua main
// thread via the bus queue.
void postNodeDiscoveredBus(const NodeInfo& node);
