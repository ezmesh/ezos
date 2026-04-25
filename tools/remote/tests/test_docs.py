"""
ez.docs — exposes the firmware-embedded markdown under lua/docs/. Two
functions: list() returns a list of paths, read(path) returns bytes.
"""

from __future__ import annotations


def test_namespace(device):
    assert device.lua_exec("return type(ez.docs)") == "table"


def test_list_returns_path_array(device):
    paths = device.lua_exec("return ez.docs.list()")
    assert isinstance(paths, list)
    assert len(paths) > 0, "no embedded docs found — firmware may be stale"
    # Every entry should be a string ending in .md
    assert all(isinstance(p, str) for p in paths)
    assert all(p.lower().endswith(".md") for p in paths), paths


def test_read_each_listed_doc(device):
    """Every path that list() reports must be readable and non-empty."""
    code = """
        local paths = ez.docs.list()
        local empties = {}
        local sizes = {}
        for _, p in ipairs(paths) do
            local body = ez.docs.read(p)
            if not body or #body == 0 then
                empties[#empties + 1] = p
            else
                sizes[#sizes + 1] = #body
            end
        end
        return { empties = empties, count = #paths, total = (function()
            local s = 0
            for _, n in ipairs(sizes) do s = s + n end
            return s
        end)() }
    """
    result = device.lua_exec(code)
    # An empty Lua array comes back as {} in JSON, which Python parses as
    # dict — accept either shape and just assert it's empty.
    empties = result["empties"]
    assert (isinstance(empties, list) and empties == []) or (
        isinstance(empties, dict) and len(empties) == 0
    ), f"some embedded docs are empty: {empties}"
    assert result["count"] >= 1
    assert result["total"] > 0


def test_read_unknown_path_returns_nil(device):
    out = device.lua_exec("return ez.docs.read('@/no/such/path.md')")
    assert out is None
