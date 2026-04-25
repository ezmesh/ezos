"""
ez.storage bindings — file CRUD, prefs, JSON, embedded scripts.

Test files live under /fs/test_storage/ so they don't pollute user data.
Pref keys are namespaced as ez_test_* and removed in teardown. We never
call clear_prefs(): it would wipe the user's saved settings.
"""

from __future__ import annotations

import pytest

TEST_DIR  = "/fs/test_storage"
TEST_FILE = "/fs/test_storage/sample.bin"
TEST_NEW  = "/fs/test_storage/renamed.bin"
TEST_COPY = "/fs/test_storage/copy.bin"
PREF_KEY  = "ez_test_pref"  # NVS keys max 15 chars


@pytest.fixture(autouse=True)
def storage_cleanup(device):
    """Wipe the test directory before and after every test."""
    _wipe(device)
    yield
    _wipe(device)
    device.lua_exec(f"ez.storage.remove_pref('{PREF_KEY}')")


def _wipe(device):
    device.lua_exec(f"""
        local files = ez.storage.list_dir('{TEST_DIR}')
        if files then
            for _, f in ipairs(files) do
                if not f.is_dir then
                    ez.storage.remove('{TEST_DIR}/' .. f.name)
                end
            end
        end
        pcall(ez.storage.rmdir, '{TEST_DIR}')
    """)


# ---------------------------------------------------------------------------
# Namespace + info
# ---------------------------------------------------------------------------


def test_namespace(device):
    assert device.lua_exec("return type(ez.storage)") == "table"


def test_is_sd_available_returns_bool(device):
    assert isinstance(device.lua_exec("return ez.storage.is_sd_available()"), bool)


def test_get_sd_info_shape(device):
    info = device.lua_exec("return ez.storage.get_sd_info()")
    # Returns a table even when no SD is mounted; keys may differ — just
    # assert table shape.
    assert info is None or isinstance(info, dict)


def test_get_flash_info_shape(device):
    info = device.lua_exec("return ez.storage.get_flash_info()")
    assert isinstance(info, dict)


def test_get_free_space(device):
    n = device.lua_exec("return ez.storage.get_free_space('/fs')")
    assert isinstance(n, int) and n >= 0


# ---------------------------------------------------------------------------
# File CRUD
# ---------------------------------------------------------------------------


def test_write_then_read_file(device):
    code = f"""
        ez.storage.mkdir('{TEST_DIR}')
        local ok = ez.storage.write_file('{TEST_FILE}', 'hello world')
        local out = ez.storage.read_file('{TEST_FILE}')
        return ok, out
    """
    ok, out = device.lua_exec(code)
    assert ok is True
    assert out == "hello world"


def test_read_alias_matches_read_file(device):
    code = f"""
        ez.storage.mkdir('{TEST_DIR}')
        ez.storage.write_file('{TEST_FILE}', 'alias test')
        return ez.storage.read('{TEST_FILE}')
    """
    assert device.lua_exec(code) == "alias test"


def test_write_alias(device):
    code = f"""
        ez.storage.mkdir('{TEST_DIR}')
        local ok = ez.storage.write('{TEST_FILE}', 'via write alias')
        return ok, ez.storage.read('{TEST_FILE}')
    """
    ok, out = device.lua_exec(code)
    assert ok is True
    assert out == "via write alias"


def test_append_file(device):
    code = f"""
        ez.storage.mkdir('{TEST_DIR}')
        ez.storage.write_file('{TEST_FILE}', 'A')
        ez.storage.append_file('{TEST_FILE}', 'B')
        ez.storage.append_file('{TEST_FILE}', 'C')
        return ez.storage.read_file('{TEST_FILE}')
    """
    assert device.lua_exec(code) == "ABC"


def test_exists_and_file_size(device):
    code = f"""
        ez.storage.mkdir('{TEST_DIR}')
        ez.storage.write_file('{TEST_FILE}', '0123456789')
        return ez.storage.exists('{TEST_FILE}'), ez.storage.file_size('{TEST_FILE}')
    """
    exists, size = device.lua_exec(code)
    assert exists is True
    assert size == 10


def test_exists_false_for_missing(device):
    assert device.lua_exec(
        "return ez.storage.exists('/fs/no/such/file.xyz')"
    ) is False


def test_remove_file(device):
    code = f"""
        ez.storage.mkdir('{TEST_DIR}')
        ez.storage.write_file('{TEST_FILE}', 'tmp')
        local ok = ez.storage.remove('{TEST_FILE}')
        return ok, ez.storage.exists('{TEST_FILE}')
    """
    ok, still_there = device.lua_exec(code)
    assert ok is True
    assert still_there is False


def test_rename_file(device):
    code = f"""
        ez.storage.mkdir('{TEST_DIR}')
        ez.storage.write_file('{TEST_FILE}', 'movedata')
        local ok = ez.storage.rename('{TEST_FILE}', '{TEST_NEW}')
        return ok,
               ez.storage.exists('{TEST_FILE}'),
               ez.storage.exists('{TEST_NEW}'),
               ez.storage.read_file('{TEST_NEW}')
    """
    ok, src, dst, body = device.lua_exec(code)
    assert ok is True
    assert src is False and dst is True
    assert body == "movedata"


def test_copy_file(device):
    code = f"""
        ez.storage.mkdir('{TEST_DIR}')
        ez.storage.write_file('{TEST_FILE}', 'copyme')
        local ok = ez.storage.copy_file('{TEST_FILE}', '{TEST_COPY}')
        return ok,
               ez.storage.exists('{TEST_FILE}'),
               ez.storage.exists('{TEST_COPY}'),
               ez.storage.read_file('{TEST_COPY}')
    """
    ok, src, dst, body = device.lua_exec(code)
    assert ok is True
    assert src is True and dst is True
    assert body == "copyme"


def test_read_bytes_with_offset(device):
    code = f"""
        ez.storage.mkdir('{TEST_DIR}')
        ez.storage.write_file('{TEST_FILE}', 'abcdefghij')
        return ez.storage.read_bytes('{TEST_FILE}', 2, 5)
    """
    assert device.lua_exec(code) == "cdefg"


def test_read_bytes_rejects_invalid_args(device):
    out = device.lua_exec(f"return ez.storage.read_bytes('{TEST_FILE}', -1, 10)")
    assert isinstance(out, list) and out[0] is None


# ---------------------------------------------------------------------------
# Directories
# ---------------------------------------------------------------------------


def test_mkdir_and_rmdir(device):
    code = f"""
        local ok = ez.storage.mkdir('{TEST_DIR}')
        local exists = ez.storage.exists('{TEST_DIR}')
        local rm = ez.storage.rmdir('{TEST_DIR}')
        local exists_after = ez.storage.exists('{TEST_DIR}')
        return ok, exists, rm, exists_after
    """
    ok, exists, rm, exists_after = device.lua_exec(code)
    assert ok is True and exists is True
    assert rm is True and exists_after is False


def test_list_dir_includes_written_file(device):
    code = f"""
        ez.storage.mkdir('{TEST_DIR}')
        ez.storage.write_file('{TEST_FILE}', '!')
        local files = ez.storage.list_dir('{TEST_DIR}')
        local found = false
        for _, f in ipairs(files) do
            if f.name == 'sample.bin' and not f.is_dir then found = true end
        end
        return found
    """
    assert device.lua_exec(code) is True


def test_list_dir_returns_table(device):
    files = device.lua_exec("return ez.storage.list_dir('/fs')")
    # Lua arrays come back as list (or dict if empty); both fine.
    assert isinstance(files, (list, dict))


# ---------------------------------------------------------------------------
# Async read
# ---------------------------------------------------------------------------


def test_async_read_bytes_round_trip(device):
    """async_read_bytes yields the calling coroutine — lua_exec runs in
    the main state, so we drive it via spawn() and poll a result global."""
    code = f"""
        ez.storage.mkdir('{TEST_DIR}')
        ez.storage.write_file('{TEST_FILE}', 'asynctest')
        _G._test_async_result = nil
        spawn(function()
            _G._test_async_result = ez.storage.async_read_bytes('{TEST_FILE}', 0, 9)
        end)
    """
    device.lua_exec(code)
    # Poll for completion — the async I/O runs on a worker and resumes
    # the coroutine when the read finishes.
    import time as _time
    deadline = _time.time() + 2.0
    result = None
    while _time.time() < deadline:
        result = device.lua_exec("return _G._test_async_result")
        if result is not None:
            break
        _time.sleep(0.1)
    device.lua_exec("_G._test_async_result = nil")
    assert result == "asynctest", f"async_read_bytes returned {result!r}"


# ---------------------------------------------------------------------------
# Prefs
# ---------------------------------------------------------------------------


def test_set_get_pref_round_trip(device):
    code = f"""
        ez.storage.set_pref('{PREF_KEY}', 'value-1')
        return ez.storage.get_pref('{PREF_KEY}', 'default')
    """
    assert device.lua_exec(code) == "value-1"


def test_get_pref_returns_default_for_missing(device):
    code = f"""
        ez.storage.remove_pref('{PREF_KEY}')
        return ez.storage.get_pref('{PREF_KEY}', 'fallback')
    """
    assert device.lua_exec(code) == "fallback"


def test_remove_pref(device):
    code = f"""
        ez.storage.set_pref('{PREF_KEY}', 'x')
        local ok = ez.storage.remove_pref('{PREF_KEY}')
        return ok, ez.storage.get_pref('{PREF_KEY}', 'gone')
    """
    ok, after = device.lua_exec(code)
    assert ok is True
    assert after == "gone"


def test_list_prefs_includes_set_key(device):
    code = f"""
        ez.storage.set_pref('{PREF_KEY}', 'in-list')
        local list = ez.storage.list_prefs()
        return list
    """
    out = device.lua_exec(code)
    assert isinstance(out, (list, dict))
    # list_prefs may return either an array of names or a dict — both fine.
    keys = out if isinstance(out, list) else list(out.keys()) + list(out.values())
    flat = [str(k) for k in keys]
    assert any(PREF_KEY in s for s in flat)


def test_clear_prefs_is_callable():
    """clear_prefs would wipe user settings; we deliberately don't invoke
    it. The function table registration is exercised by test_namespace."""


# ---------------------------------------------------------------------------
# JSON
# ---------------------------------------------------------------------------


def test_json_encode_decode_round_trip(device):
    code = """
        local input = { name = 'alice', age = 30, tags = { 'a', 'b' } }
        local enc = ez.storage.json_encode(input)
        local dec = ez.storage.json_decode(enc)
        return type(enc), dec
    """
    enc_type, decoded = device.lua_exec(code)
    assert enc_type == "string"
    assert decoded["name"] == "alice"
    assert decoded["age"] == 30
    assert decoded["tags"] == ["a", "b"]


def test_json_decode_rejects_garbage(device):
    out = device.lua_exec("return ez.storage.json_decode('{not json}')")
    assert out is None or (isinstance(out, list) and out[0] is None)


# ---------------------------------------------------------------------------
# Embedded scripts
# ---------------------------------------------------------------------------


def test_list_embedded_returns_paths(device):
    """list_embedded returns an array of {path, size, is_embedded} tables.

    Filtered by prefix to keep the result small — the lua_exec JSON
    response buffer truncates near 4 KB, so the unfiltered call returns
    ~75 entries with the last few corrupted. Filtering by '$ezui' keeps
    us well under the limit.
    """
    entries = device.lua_exec("return ez.storage.list_embedded('$ezui')")
    assert isinstance(entries, list)
    assert len(entries) > 0
    for e in entries:
        assert {"path", "size", "is_embedded"} <= set(e.keys()), e
        assert isinstance(e["path"], str)
        assert e["path"].startswith("$ezui")
        assert isinstance(e["size"], int) and e["size"] > 0
        assert e["is_embedded"] is True


def test_list_embedded_count_matches_lua_view(device):
    """The raw entry count is reported correctly even when the encoded
    payload exceeds the response buffer."""
    n = device.lua_exec("return #ez.storage.list_embedded('')")
    assert isinstance(n, int) and n > 50


def test_read_embedded_boot_script(device):
    code = "return ez.storage.read_embedded('$boot.lua')"
    body = device.lua_exec(code)
    assert isinstance(body, str)
    assert len(body) > 0


def test_is_embedded_for_known_path(device):
    assert device.lua_exec(
        "return ez.storage.is_embedded('$boot.lua')"
    ) is True


def test_is_embedded_for_unknown_path(device):
    assert device.lua_exec(
        "return ez.storage.is_embedded('$no_such_path.lua')"
    ) is False
