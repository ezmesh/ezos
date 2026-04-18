#!/usr/bin/env python3
"""
Embed Lua scripts into firmware binary.

Generates a C++ file with all Lua scripts compiled to Lua 5.4 bytecode.
Pipeline: source → strip comments/whitespace → compile to bytecode → embed.

Can be run:
1. As a PlatformIO pre-build script (via extra_scripts)
2. Directly from command line (python scripts/embed_lua_scripts.py)
"""

import os
import re
import sys
import subprocess
import shutil
from pathlib import Path

# Size limits for warnings
SIZE_WARNING_THRESHOLD = 800 * 1024  # 800KB
SIZE_ERROR_THRESHOLD = 1024 * 1024   # 1MB

# Lua source directory (relative to project root)
LUA_SOURCE_DIR = "lua"

# Virtual path prefix for embedded scripts
# C++ looks up scripts as "$boot.lua", require("ezui.core") → "$ezui/core.lua"
VIRTUAL_PREFIX = "$"


# ---------------------------------------------------------------------------
# Comment and whitespace stripping
# ---------------------------------------------------------------------------

def strip_lua_source(source: str) -> str:
    """Strip comments and collapse unnecessary whitespace from Lua source."""
    result = []
    i = 0
    n = len(source)

    while i < n:
        # Long comment: --[=*[  ...  ]=*]
        if source[i:i+4] == '--[=' or source[i:i+3] == '--[':
            # Count equals signs
            j = i + 2
            eq_count = 0
            while j < n and source[j] == '=':
                eq_count += 1
                j += 1
            if j < n and source[j] == '[':
                # Valid long comment opening, find matching close
                close = ']' + '=' * eq_count + ']'
                end = source.find(close, j + 1)
                if end >= 0:
                    i = end + len(close)
                    continue
                else:
                    # Unterminated long comment, skip rest
                    break
            # Not a valid long comment, treat -- as line comment
            end = source.find('\n', i)
            if end >= 0:
                result.append('\n')
                i = end + 1
            else:
                break
            continue

        # Line comment: -- to end of line
        if source[i:i+2] == '--':
            end = source.find('\n', i)
            if end >= 0:
                result.append('\n')
                i = end + 1
            else:
                break
            continue

        # Long string literal: [=*[ ... ]=*] (preserve as-is)
        if source[i] == '[':
            j = i + 1
            eq_count = 0
            while j < n and source[j] == '=':
                eq_count += 1
                j += 1
            if j < n and source[j] == '[':
                close = ']' + '=' * eq_count + ']'
                end = source.find(close, j + 1)
                if end >= 0:
                    result.append(source[i:end + len(close)])
                    i = end + len(close)
                    continue

        # Quoted string (preserve as-is)
        if source[i] in ('"', "'"):
            quote = source[i]
            result.append(quote)
            i += 1
            while i < n:
                if source[i] == '\\' and i + 1 < n:
                    result.append(source[i:i+2])
                    i += 2
                elif source[i] == quote:
                    result.append(quote)
                    i += 1
                    break
                else:
                    result.append(source[i])
                    i += 1
            continue

        # Regular character
        result.append(source[i])
        i += 1

    text = ''.join(result)

    # Collapse blank lines (keep single newlines for line number accuracy in errors)
    text = re.sub(r'\n[ \t]+\n', '\n\n', text)
    # Collapse runs of blank lines to single blank line
    text = re.sub(r'\n{3,}', '\n\n', text)
    # Strip trailing whitespace on each line
    text = re.sub(r'[ \t]+\n', '\n', text)
    # Strip leading/trailing whitespace
    text = text.strip() + '\n'

    return text


# ---------------------------------------------------------------------------
# Bytecode compilation
# ---------------------------------------------------------------------------

def find_luac(project_root: Path) -> str:
    """Find the Lua 5.4 bytecode compiler (32-bit, matching ESP32 config)."""
    # Prefer the project's cross-compiled luac (built with LUA_32BITS=1)
    local_luac = project_root / "tools" / "bin" / "luac32"
    if local_luac.exists() and os.access(str(local_luac), os.X_OK):
        try:
            out = subprocess.run([str(local_luac), '-v'], capture_output=True, text=True, timeout=5)
            if '5.4' in (out.stdout + out.stderr):
                return str(local_luac)
        except (subprocess.TimeoutExpired, OSError):
            pass

    # Fall back to system luac (may not match ESP32 32-bit config!)
    for name in ['luac54', 'luac5.4', 'luac']:
        path = shutil.which(name)
        if path:
            try:
                out = subprocess.run([path, '-v'], capture_output=True, text=True, timeout=5)
                version_str = out.stdout + out.stderr
                if '5.4' in version_str:
                    print(f"  WARNING: Using system {path} - bytecode may not match ESP32 32-bit config")
                    print(f"           Run: cd .pio/libdeps/t-deck-plus/Esp32Lua/src/lua && "
                          f"cc -O2 -DLUA_32BITS=1 -o ../../../../../../tools/bin/luac32 luac.c l*.c -lm")
                    return path
            except (subprocess.TimeoutExpired, OSError):
                continue

    return None


def compile_to_bytecode(luac_path: str, source: str, chunk_name: str) -> bytes:
    """Compile Lua source to bytecode using luac. Returns bytecode or None."""
    import tempfile
    try:
        with tempfile.NamedTemporaryFile(mode='w', suffix='.lua', delete=False) as src_f:
            src_f.write(source)
            src_path = src_f.name

        out_path = src_path + '.out'
        result = subprocess.run(
            [luac_path, '-s', '-o', out_path, src_path],
            capture_output=True, text=True, timeout=10
        )

        if result.returncode == 0 and os.path.exists(out_path):
            bytecode = Path(out_path).read_bytes()
            return bytecode
        else:
            err = result.stderr.strip()
            if err:
                print(f"    luac warning for {chunk_name}: {err}")
            return None
    except (subprocess.TimeoutExpired, OSError) as e:
        print(f"    luac error for {chunk_name}: {e}")
        return None
    finally:
        for p in [src_path, out_path]:
            try:
                os.unlink(p)
            except OSError:
                pass


# ---------------------------------------------------------------------------
# Embedding
# ---------------------------------------------------------------------------

def escape_bytes_for_c(data: bytes) -> str:
    """Convert bytes to C byte array initializer for binary-safe embedding."""
    # For bytecode (binary data), use a byte array instead of string literal
    # to avoid hex escape ambiguity issues
    parts = []
    for i in range(0, len(data), 16):
        chunk = data[i:i+16]
        parts.append(','.join(f'0x{b:02x}' for b in chunk))
    return ','.join(parts)


def generate_var_name(path: str) -> str:
    """Generate a valid C variable name from a path."""
    name = path.lstrip('/')
    name = ''.join(c if c.isalnum() else '_' for c in name)
    return f"lua_{name}"


def find_lua_scripts(project_root: Path) -> list:
    """Find all .lua files and return (virtual_path, file_path) tuples."""
    lua_dir = project_root / LUA_SOURCE_DIR
    if not lua_dir.exists():
        return []

    scripts = []
    for lua_file in lua_dir.rglob("*.lua"):
        relative = lua_file.relative_to(lua_dir)
        relative_str = str(relative).replace("\\", "/")
        if VIRTUAL_PREFIX.endswith("/"):
            virtual_path = VIRTUAL_PREFIX + relative_str
        else:
            virtual_path = VIRTUAL_PREFIX + relative_str
        scripts.append((virtual_path, lua_file))

    scripts.sort(key=lambda x: x[0])
    return scripts


def generate_embedded_scripts_cpp(script_data: list, output_path: Path) -> int:
    """Generate the C++ file with embedded scripts. Returns total embedded size."""
    total_size = 0

    lines = [
        "// AUTO-GENERATED FILE - DO NOT EDIT",
        "// Generated by scripts/embed_lua_scripts.py",
        "//",
        f"// Total embedded Lua scripts: {len(script_data)}",
        "",
        '#include "embedded_lua_scripts.h"',
        '#include <cstring>',
        "",
        "namespace embedded_lua {",
        "",
    ]

    entries = []
    for virtual_path, content in script_data:
        var_name = generate_var_name(virtual_path)
        total_size += len(content)
        lines.append(f"// {virtual_path} ({len(content)} bytes)")
        byte_data = escape_bytes_for_c(content)
        lines.append(f'static const char {var_name}[] = {{{byte_data}}};')
        lines.append("")
        entries.append((virtual_path, var_name, len(content)))

    # Update header comment with total size
    lines[3] = f"// Total embedded size: {total_size:,} bytes ({total_size/1024:.1f} KB)"

    lines.append("// Lookup table")
    lines.append("static const struct {")
    lines.append("    const char* path;")
    lines.append("    const char* content;")
    lines.append("    size_t size;")
    lines.append("} scripts[] = {")

    for virtual_path, var_name, size in entries:
        lines.append(f'    {{"{virtual_path}", {var_name}, {size}}},')

    lines.append("};")
    lines.append("")
    lines.append(f"static const size_t script_count = {len(entries)};")
    lines.append("")

    lines.extend([
        "const char* get_script(const char* path, size_t* out_size) {",
        "    for (size_t i = 0; i < script_count; i++) {",
        "        if (strcmp(scripts[i].path, path) == 0) {",
        "            if (out_size) *out_size = scripts[i].size;",
        "            return scripts[i].content;",
        "        }",
        "    }",
        "    return nullptr;",
        "}",
        "",
        "size_t get_script_count() {",
        f"    return {len(entries)};",
        "}",
        "",
        "size_t get_total_size() {",
        f"    return {total_size};",
        "}",
        "",
        "const char* get_script_path(size_t index) {",
        "    if (index >= script_count) return nullptr;",
        "    return scripts[index].path;",
        "}",
        "",
        "size_t get_script_size(size_t index) {",
        "    if (index >= script_count) return 0;",
        "    return scripts[index].size;",
        "}",
        "",
        "} // namespace embedded_lua",
        "",
    ])

    output_path.write_text('\n'.join(lines))
    return total_size


def generate_header(output_path: Path):
    """Generate the header file."""
    lines = [
        "// AUTO-GENERATED FILE - DO NOT EDIT",
        "// Generated by scripts/embed_lua_scripts.py",
        "",
        "#pragma once",
        "",
        "#include <cstddef>",
        "",
        "namespace embedded_lua {",
        "",
        f"// Get embedded script content by path (e.g., \"{VIRTUAL_PREFIX}/boot.lua\")",
        "// Returns nullptr if not found, sets out_size if provided",
        "const char* get_script(const char* path, size_t* out_size = nullptr);",
        "",
        "// Get total number of embedded scripts",
        "size_t get_script_count();",
        "",
        "// Get total size of all embedded scripts in bytes",
        "size_t get_total_size();",
        "",
        "// Get script path by index (0 to get_script_count()-1)",
        "const char* get_script_path(size_t index);",
        "",
        "// Get script size by index",
        "size_t get_script_size(size_t index);",
        "",
        "} // namespace embedded_lua",
        "",
    ]
    output_path.write_text('\n'.join(lines))


def embed_lua_scripts(project_root: Path) -> int:
    """Main embedding function. Returns 0 on success, 1 on error."""
    src_dir = project_root / "src"
    output_cpp = src_dir / "lua" / "embedded_lua_scripts.cpp"
    output_h = src_dir / "lua" / "embedded_lua_scripts.h"

    scripts = find_lua_scripts(project_root)

    if not scripts:
        print(f"WARNING: No Lua scripts found in {LUA_SOURCE_DIR}/")
        generate_header(output_h)
        output_cpp.write_text(
            "// AUTO-GENERATED FILE - DO NOT EDIT\n"
            "// No Lua scripts found\n"
            '#include "embedded_lua_scripts.h"\n'
            "namespace embedded_lua {\n"
            "const char* get_script(const char*, size_t*) { return nullptr; }\n"
            "size_t get_script_count() { return 0; }\n"
            "size_t get_total_size() { return 0; }\n"
            "const char* get_script_path(size_t) { return nullptr; }\n"
            "size_t get_script_size(size_t) { return 0; }\n"
            "}\n"
        )
        return 0

    print(f"Embedding {len(scripts)} Lua scripts...")

    # Try to find luac for bytecode compilation
    luac = find_luac(project_root)
    if luac:
        print(f"  Bytecode compiler: {luac}")
    else:
        print("  No luac 5.4 found - embedding stripped source (no bytecode)")

    # Process each script: strip → optionally compile to bytecode
    source_size = 0
    script_data = []

    for virtual_path, file_path in scripts:
        raw = file_path.read_text(encoding='utf-8')
        source_size += len(raw.encode('utf-8'))

        # Strip comments and whitespace
        stripped = strip_lua_source(raw)

        # Try bytecode compilation
        content = None
        if luac:
            bytecode = compile_to_bytecode(luac, stripped, virtual_path)
            if bytecode:
                content = bytecode

        # Fall back to stripped source
        if content is None:
            content = stripped.encode('utf-8')

        script_data.append((virtual_path, content))

    generate_header(output_h)
    total_size = generate_embedded_scripts_cpp(script_data, output_cpp)

    pct_saved = ((source_size - total_size) / source_size * 100) if source_size > 0 else 0
    print(f"  Source size: {source_size:,} bytes ({source_size/1024:.1f} KB)")
    print(f"  Embedded size: {total_size:,} bytes ({total_size/1024:.1f} KB)")
    print(f"  Saved: {source_size - total_size:,} bytes ({pct_saved:.0f}%)")
    print(f"  Output: {output_cpp}")

    # Size warnings
    if total_size > SIZE_ERROR_THRESHOLD:
        print(f"\n*** ERROR: Embedded scripts exceed {SIZE_ERROR_THRESHOLD/1024:.0f}KB limit! ***")
        print(f"    Current size: {total_size/1024:.1f}KB")
        return 1
    elif total_size > SIZE_WARNING_THRESHOLD:
        pct = (total_size / SIZE_ERROR_THRESHOLD) * 100
        print(f"\n*** WARNING: Embedded scripts at {pct:.0f}% of {SIZE_ERROR_THRESHOLD/1024:.0f}KB limit ***")
        print(f"    Current size: {total_size/1024:.1f}KB")
        print(f"    Remaining: {(SIZE_ERROR_THRESHOLD - total_size)/1024:.1f}KB")

    return 0


# PlatformIO pre-build hook
try:
    Import("env")

    cpp_defines = env.get("CPPDEFINES", [])
    build_flags = env.get("BUILD_FLAGS", [])

    skip_embedding = False
    for d in cpp_defines:
        if isinstance(d, tuple):
            if d[0] == "NO_EMBEDDED_SCRIPTS":
                skip_embedding = True
                break
        elif d == "NO_EMBEDDED_SCRIPTS":
            skip_embedding = True
            break

    if not skip_embedding:
        skip_embedding = any("NO_EMBEDDED_SCRIPTS" in str(f) for f in build_flags)

    if skip_embedding:
        print("NO_EMBEDDED_SCRIPTS defined - skipping script embedding")
    else:
        project_dir = Path(env.get("PROJECT_DIR", "."))
        result = embed_lua_scripts(project_dir)
        if result != 0:
            env.Exit(1)

except Exception as e:
    print(f"Note: Not running under PlatformIO ({e})")
    pass


def main():
    """Direct execution entry point."""
    script_dir = Path(__file__).parent
    project_root = script_dir.parent
    return embed_lua_scripts(project_root)


if __name__ == "__main__":
    sys.exit(main())
