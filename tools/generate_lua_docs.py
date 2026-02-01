#!/usr/bin/env python3
"""
Lua API Documentation Generator for ezOS

Generates two documentation sets:
1. Development docs (docs/manuals/development/shell/) - API reference for developers
2. User docs (docs/manuals/shell/) - Shell guide with settings reference

## C++ Binding Documentation

Module descriptions are documented at the top of each binding file:

    // @module ez.display
    // @brief Display drawing and rendering functions
    // @description
    // The display module provides all 2D drawing primitives and text rendering
    // for the 320x240 LCD. All drawing is double-buffered.
    // @end

Function docs use the following format:

    // @lua ez.module.function_name(arg1, arg2) -> return_type
    // @brief Short description of the function
    // @description Longer multi-line description
    // @param arg1 Description of first argument
    // @param arg2 Description of second argument
    // @return Description of return value
    // @since 0.2.0
    // @deprecated Use other_function() instead
    // @see other_function
    // @example
    // local result = ez.module.function_name("hello", 42)
    // @end

Bus messages are documented with:

    // @bus topic/name
    // @brief Short description
    // @description When this event is posted
    // @payload { field: type, ... } or "string description"
    // @example
    // ez.bus.subscribe("topic/name", function(data) ... end)
    // @end

## Lua Settings Documentation

Settings are parsed from data/scripts/ui/screens/settings_category.lua.
Each setting has a `desc` field for documentation:

    {name = "wifi_enabled", label = "WiFi Radio", type = "toggle",
     desc = "Enable or disable the WiFi radio..."},
"""

import os
import re
import sys
from pathlib import Path
from dataclasses import dataclass, field
from typing import List, Dict, Optional, Set, Tuple
import html
import json

# Configuration
BINDING_DIRS = [
    'lua/bindings',           # Main bindings
    'hardware',               # Hardware-level bindings (if any)
]

# Functions to exclude from documentation
EXCLUDED_FUNCTIONS: Set[str] = set()

# Version history for changelog
VERSION_HISTORY = [
    ("0.1.0", "2024-01-15", "Initial release"),
    ("0.2.0", "2024-03-01", "Added GPS, mesh networking"),
    ("0.3.0", "2024-06-01", "Added sprites, audio synthesis"),
]

@dataclass
class LuaParam:
    name: str
    description: str

@dataclass
class LuaFunction:
    module: str
    name: str
    signature: str
    brief: str = ""
    description: str = ""
    params: List[LuaParam] = field(default_factory=list)
    returns: str = ""
    example: str = ""
    since: str = ""
    deprecated: str = ""
    see_also: List[str] = field(default_factory=list)
    source_file: str = ""
    line_number: int = 0

    @property
    def fqn(self) -> str:
        """Return fully qualified name like module.function"""
        return f"{self.module}.{self.name}"

    @property
    def anchor(self) -> str:
        """Return HTML anchor ID"""
        return f"{self.module}-{self.name}".lower()

    @property
    def is_deprecated(self) -> bool:
        return bool(self.deprecated)

@dataclass
class BusMessage:
    topic: str
    brief: str = ""
    description: str = ""
    payload: str = ""
    example: str = ""
    source_file: str = ""
    see_also: List[str] = field(default_factory=list)

    @property
    def anchor(self) -> str:
        return f"bus-{self.topic.replace('/', '-')}".lower()

    @property
    def related_module(self) -> str:
        """Get the module name from the source file."""
        if self.source_file:
            return self.source_file.lower().replace('_bindings.cpp', '').replace('_bindings.h', '')
        return ""

@dataclass
class ModuleInfo:
    """Module-level documentation parsed from @module tags."""
    name: str
    brief: str = ""
    description: str = ""

@dataclass
class LuaModule:
    name: str
    brief: str = ""
    description: str = ""
    functions: List[LuaFunction] = field(default_factory=list)

@dataclass
class Setting:
    """A single setting parsed from Lua settings file."""
    name: str
    label: str
    setting_type: str
    default_value: str
    description: str = ""
    options: List[str] = field(default_factory=list)
    min_val: Optional[str] = None
    max_val: Optional[str] = None
    suffix: str = ""

@dataclass
class SettingsCategory:
    """A category of settings."""
    key: str
    title: str
    description: str = ""
    settings: List[Setting] = field(default_factory=list)

@dataclass
class MenuItem:
    """A menu item from the main menu."""
    label: str
    description: str
    shortcut: str = ""
    enabled: bool = True

# Introduction content for the documentation (HTML format)
INTRODUCTION = """
<h2>Introduction</h2>

<p>ezOS provides a comprehensive Lua API for building applications on the T-Deck Plus hardware.
This reference documents all available functions, organized by module.</p>

<h3>Memory Model</h3>

<ul>
<li><strong>Lua allocations use PSRAM</strong> — The Lua VM allocates all memory from the 8MB PSRAM, not the limited 320KB internal SRAM</li>
<li><strong>Strings are immutable</strong> — Each string operation creates a new string; avoid concatenation in loops</li>
<li><strong>Tables use memory</strong> — Empty tables take ~40 bytes; consider reusing tables in performance-critical code</li>
<li><strong>Garbage collection</strong> — Runs automatically, but you can trigger it with <code>ez.system.gc()</code></li>
</ul>

<h3>Coroutines and Yielding</h3>

<p>Many ezOS APIs are designed for coroutine-based async programming:</p>

<pre><code><span class="kw">local</span> <span class="kw">function</span> <span class="fn">load_async</span>()
    <span class="kw">local</span> data = <span class="fn">load_module</span>(<span class="str">"/scripts/heavy_module.lua"</span>)  <span class="cmt">-- Yields while loading</span>
    <span class="fn">process</span>(data)
<span class="kw">end</span>
<span class="fn">spawn</span>(load_async)</code></pre>

<p>Functions that yield are noted in their documentation. Don't call yielding functions
outside of a coroutine context.</p>

<h3>Error Handling</h3>

<p>Most functions return <code>nil</code> on error rather than throwing. Check return values:</p>

<pre><code><span class="kw">local</span> file = ez.storage.<span class="fn">read_file</span>(<span class="str">"/path"</span>)
<span class="kw">if not</span> file <span class="kw">then</span>
    <span class="fn">print</span>(<span class="str">"Failed to read file"</span>)
    <span class="kw">return</span>
<span class="kw">end</span></code></pre>

<h3>Color Format</h3>

<p>Display functions use <strong>RGB565</strong> format (16-bit color). Use <code>ez.display.rgb(r, g, b)</code> to
convert from 8-bit RGB, or use predefined colors from <code>ez.display.colors</code>:</p>

<pre><code><span class="kw">local</span> red = ez.display.colors.RED
<span class="kw">local</span> custom = ez.display.<span class="fn">rgb</span>(<span class="num">128</span>, <span class="num">64</span>, <span class="num">255</span>)</code></pre>

<h3>Coordinate Systems</h3>

<ul>
<li><strong>Pixel coordinates</strong> start at (0, 0) in the top-left corner</li>
<li><strong>Character cells</strong> are used by text-mode functions like <code>draw_box()</code></li>
<li>Display size: 320×240 pixels, typically 40×15 character cells with medium font</li>
</ul>

<h3>Best Practices</h3>

<ol>
<li><strong>Prefer local variables</strong> — Globals are slower and use more memory</li>
<li><strong>Reuse tables</strong> — Clear and reuse instead of creating new ones</li>
<li><strong>Batch drawing</strong> — Draw everything, then call <code>flush()</code> once per frame</li>
<li><strong>Unload unused modules</strong> — Use <code>unload_module()</code> to free memory</li>
<li><strong>Check memory</strong> — Use <code>ez.system.get_lua_memory()</code> to monitor usage</li>
</ol>
"""

BUS_INTRO = """
<h2>Message Bus</h2>

<p>The message bus provides publish/subscribe communication between components.
Use <code>ez.bus.subscribe()</code> to listen for events and <code>ez.bus.post()</code> to publish them.</p>

<h3>Subscribing to Messages</h3>

<pre><code><span class="kw">local</span> sub_id = ez.bus.<span class="fn">subscribe</span>(<span class="str">"channel/message"</span>, <span class="kw">function</span>(data)
    <span class="fn">print</span>(<span class="str">"New message:"</span>, data.text)
<span class="kw">end</span>)

<span class="cmt">-- Later, to unsubscribe:</span>
ez.bus.<span class="fn">unsubscribe</span>(sub_id)</code></pre>

<h3>Publishing Messages</h3>

<pre><code>ez.bus.<span class="fn">post</span>(<span class="str">"settings/changed"</span>, <span class="str">"brightness=200"</span>)
ez.bus.<span class="fn">post</span>(<span class="str">"custom/event"</span>, { value = <span class="num">42</span>, name = <span class="str">"test"</span> })</code></pre>

<h3>Available Topics</h3>
"""

def parse_binding_file(filepath: Path) -> Tuple[List[LuaFunction], List[BusMessage], List[ModuleInfo]]:
    """Parse a C++ binding file for Lua documentation comments."""
    functions = []
    bus_messages = []
    module_infos = []

    with open(filepath, 'r') as f:
        content = f.read()
        lines = content.split('\n')

    # Find line numbers for doc blocks
    def find_line_number(pos: int) -> int:
        return content[:pos].count('\n') + 1

    # Pattern for module doc blocks
    module_pattern = re.compile(
        r'// @module\s+(.+?)\s*\n'
        r'((?://.*\n)*)',
        re.MULTILINE
    )

    # Pattern for function doc blocks
    func_pattern = re.compile(
        r'// @lua\s+(.+?)\s*\n'
        r'((?://.*\n)*)',
        re.MULTILINE
    )

    # Pattern for bus message doc blocks
    bus_pattern = re.compile(
        r'// @bus\s+(.+?)\s*\n'
        r'((?://.*\n)*)',
        re.MULTILINE
    )

    # Parse all module docs
    for module_match in module_pattern.finditer(content):
        module_name = module_match.group(1).strip()
        # Remove ez. prefix if present
        if module_name.startswith('ez.'):
            module_name = module_name[3:]
        doc_block = module_match.group(2)
        module_info = ModuleInfo(name=module_name)
        parse_module_doc_block(doc_block, module_info)
        module_infos.append(module_info)

    # Parse function docs
    for match in func_pattern.finditer(content):
        signature = match.group(1).strip()
        doc_block = match.group(2)
        line_num = find_line_number(match.start())

        # Parse module and function name from signature
        sig_match = re.match(r'(?:(\w+)\.)?(\w+)\.(\w+)\((.*?)\)(?:\s*->\s*(.+))?', signature)
        if sig_match:
            module = sig_match.group(2)
            name = sig_match.group(3)
        else:
            sig_match = re.match(r'(\w+):(\w+)\((.*?)\)(?:\s*->\s*(.+))?', signature)
            if sig_match:
                module = sig_match.group(1)
                name = sig_match.group(2)
            else:
                sig_match = re.match(r'(\w+)\((.*?)\)(?:\s*->\s*(.+))?', signature)
                if sig_match:
                    module = "global"
                    name = sig_match.group(1)
                else:
                    continue

        if name in EXCLUDED_FUNCTIONS:
            continue

        func = LuaFunction(
            module=module,
            name=name,
            signature=signature,
            source_file=filepath.name,
            line_number=line_num
        )

        # Parse doc block
        parse_doc_block(doc_block, func)
        functions.append(func)

    # Parse bus message docs
    for match in bus_pattern.finditer(content):
        topic = match.group(1).strip()
        doc_block = match.group(2)

        bus_msg = BusMessage(topic=topic, source_file=filepath.name)
        parse_bus_doc_block(doc_block, bus_msg)
        bus_messages.append(bus_msg)

    return functions, bus_messages, module_infos

def parse_module_doc_block(doc_block: str, module_info: ModuleInfo):
    """Parse module documentation block."""
    in_description = False
    description_lines = []

    for line in doc_block.split('\n'):
        line = line.strip()
        if not line.startswith('//'):
            continue
        line = line[2:].strip()

        if line.startswith('@brief'):
            in_description = False
            module_info.brief = line[6:].strip()
        elif line.startswith('@description'):
            in_description = True
            content = line[12:].strip()
            if content:
                description_lines.append(content)
        elif line.startswith('@end'):
            in_description = False
        elif line.startswith('@'):
            in_description = False
        elif in_description:
            description_lines.append(line)
        elif not module_info.brief and line:
            # First non-tag line is the brief
            module_info.brief = line

    if description_lines:
        module_info.description = '\n'.join(description_lines)

def parse_doc_block(doc_block: str, func: LuaFunction):
    """Parse documentation block and populate function object."""
    in_example = False
    in_description = False
    example_lines = []
    description_lines = []

    for line in doc_block.split('\n'):
        line = line.strip()
        if not line.startswith('//'):
            continue
        line = line[2:].strip()

        if line.startswith('@brief'):
            in_description = False
            func.brief = line[6:].strip()
        elif line.startswith('@description'):
            in_description = True
            content = line[12:].strip()
            if content:
                description_lines.append(content)
        elif line.startswith('@param'):
            in_description = False
            param_match = re.match(r'@param\s+(\w+)\s+(.*)', line)
            if param_match:
                func.params.append(LuaParam(
                    name=param_match.group(1),
                    description=param_match.group(2)
                ))
        elif line.startswith('@return'):
            in_description = False
            func.returns = line[7:].strip()
        elif line.startswith('@since'):
            in_description = False
            func.since = line[6:].strip()
        elif line.startswith('@deprecated'):
            in_description = False
            func.deprecated = line[11:].strip()
        elif line.startswith('@see'):
            in_description = False
            refs = line[4:].strip().split(',')
            func.see_also.extend([r.strip() for r in refs if r.strip()])
        elif line.startswith('@example'):
            in_description = False
            in_example = True
        elif line.startswith('@end'):
            in_example = False
            func.example = '\n'.join(example_lines)
        elif line.startswith('@'):
            in_description = False
        elif in_example:
            example_lines.append(line)
        elif in_description:
            description_lines.append(line)

    if description_lines:
        func.description = '\n'.join(description_lines)

def parse_bus_doc_block(doc_block: str, bus_msg: BusMessage):
    """Parse bus message documentation block."""
    in_example = False
    in_description = False
    example_lines = []
    description_lines = []

    for line in doc_block.split('\n'):
        line = line.strip()
        if not line.startswith('//'):
            continue
        line = line[2:].strip()

        if line.startswith('@brief'):
            in_description = False
            bus_msg.brief = line[6:].strip()
        elif line.startswith('@description'):
            in_description = True
            content = line[12:].strip()
            if content:
                description_lines.append(content)
        elif line.startswith('@payload'):
            in_description = False
            bus_msg.payload = line[8:].strip()
        elif line.startswith('@see'):
            in_description = False
            refs = line[4:].strip().split(',')
            bus_msg.see_also.extend([r.strip() for r in refs if r.strip()])
        elif line.startswith('@example'):
            in_description = False
            in_example = True
        elif line.startswith('@end'):
            in_example = False
            bus_msg.example = '\n'.join(example_lines)
        elif line.startswith('@'):
            in_description = False
        elif in_example:
            example_lines.append(line)
        elif in_description:
            description_lines.append(line)

    if description_lines:
        bus_msg.description = '\n'.join(description_lines)

def find_binding_files(src_dir: Path) -> List[Path]:
    """Find all Lua binding C++ files in configured directories."""
    files = []
    for subdir in BINDING_DIRS:
        binding_path = src_dir / subdir
        if binding_path.exists():
            files.extend(binding_path.glob('*_bindings.cpp'))
            files.extend(binding_path.glob('*_bindings.h'))
    return sorted(set(files))

def format_markdown_table(headers: List[str], rows: List[List[str]], min_width: int = 3) -> str:
    """Format a markdown table with aligned columns.

    Args:
        headers: Column header strings
        rows: List of rows, each row is a list of cell strings
        min_width: Minimum column width

    Returns:
        Formatted markdown table string
    """
    # Calculate column widths
    col_widths = [max(min_width, len(h)) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            if i < len(col_widths):
                col_widths[i] = max(col_widths[i], len(cell))

    # Build header row
    header_cells = [h.ljust(col_widths[i]) for i, h in enumerate(headers)]
    header_line = "| " + " | ".join(header_cells) + " |"

    # Build separator row
    sep_cells = ["-" * col_widths[i] for i in range(len(headers))]
    sep_line = "|-" + "-|-".join(sep_cells) + "-|"

    # Build data rows
    data_lines = []
    for row in rows:
        # Pad row to match header count
        padded_row = row + [""] * (len(headers) - len(row))
        cells = [cell.ljust(col_widths[i]) for i, cell in enumerate(padded_row[:len(headers)])]
        data_lines.append("| " + " | ".join(cells) + " |")

    return "\n".join([header_line, sep_line] + data_lines)

def parse_settings_file(filepath: Path) -> List[SettingsCategory]:
    """Parse settings from Lua settings_category.lua file."""
    categories = []

    with open(filepath, 'r') as f:
        content = f.read()

    # Parse CATEGORY_INFO table for category metadata
    category_info = {}
    cat_info_match = re.search(r'CATEGORY_INFO\s*=\s*\{(.+?)\n\}', content, re.DOTALL)
    if cat_info_match:
        cat_block = cat_info_match.group(1)
        # Parse each category's info
        for cat_match in re.finditer(r'(\w+)\s*=\s*\{[^}]*title\s*=\s*"([^"]+)"[^}]*desc\s*=\s*"([^"]+)"', cat_block):
            key = cat_match.group(1)
            title = cat_match.group(2)
            desc = cat_match.group(3)
            category_info[key] = {'title': title, 'desc': desc}

    # Find ALL_SETTINGS block start
    all_settings_start = content.find('ALL_SETTINGS')
    if all_settings_start == -1:
        return categories

    # Use a simple state machine to find balanced braces for each category
    # Look for patterns like: category_name = {
    category_starts = list(re.finditer(r'^\s+(\w+)\s*=\s*\{', content[all_settings_start:], re.MULTILINE))

    for i, cat_match in enumerate(category_starts):
        cat_key = cat_match.group(1)
        if cat_key in ('CATEGORY_INFO', 'ALL_SETTINGS'):
            continue

        start_pos = all_settings_start + cat_match.end() - 1  # Position of opening {
        brace_count = 1
        pos = start_pos + 1

        # Find matching closing brace
        while brace_count > 0 and pos < len(content):
            if content[pos] == '{':
                brace_count += 1
            elif content[pos] == '}':
                brace_count -= 1
            pos += 1

        cat_content = content[start_pos:pos]

        info = category_info.get(cat_key, {})
        category = SettingsCategory(
            key=cat_key,
            title=info.get('title', cat_key.title()),
            description=info.get('desc', '')
        )

        # Find each setting block: {...}
        # Use brace matching for each setting
        setting_starts = list(re.finditer(r'\{[^{}]*name\s*=\s*"', cat_content))
        for setting_start in setting_starts:
            brace_pos = setting_start.start()
            brace_count = 1
            pos = brace_pos + 1

            # Find matching closing brace
            while brace_count > 0 and pos < len(cat_content):
                if cat_content[pos] == '{':
                    brace_count += 1
                elif cat_content[pos] == '}':
                    brace_count -= 1
                pos += 1

            setting_block = cat_content[brace_pos:pos]

            # Extract name
            name_match = re.search(r'name\s*=\s*"([^"]+)"', setting_block)
            if not name_match:
                continue
            name = name_match.group(1)

            # Extract fields from setting block
            def extract_field(field_name, default=""):
                match = re.search(rf'{field_name}\s*=\s*"([^"]*)"', setting_block)
                if match:
                    return match.group(1)
                # Try non-string values (but stop at comma or closing brace, not newline)
                match = re.search(rf'{field_name}\s*=\s*([^,\}}\n]+)', setting_block)
                if match:
                    val = match.group(1).strip()
                    if val.startswith('"') or val.startswith("'"):
                        return val.strip('"\'')
                    return val
                return default

            label = extract_field('label')
            setting_type = extract_field('type')
            value = extract_field('value')
            desc = extract_field('desc')
            min_val = extract_field('min')
            max_val = extract_field('max')
            suffix = extract_field('suffix')

            # Parse options array if present (handle nested braces)
            options = []
            options_start = setting_block.find('options')
            if options_start != -1:
                # Find the opening brace
                brace_start = setting_block.find('{', options_start)
                if brace_start != -1:
                    brace_count = 1
                    pos = brace_start + 1
                    while brace_count > 0 and pos < len(setting_block):
                        if setting_block[pos] == '{':
                            brace_count += 1
                        elif setting_block[pos] == '}':
                            brace_count -= 1
                        pos += 1
                    opts_str = setting_block[brace_start:pos]
                    options = re.findall(r'"([^"]+)"', opts_str)

            setting = Setting(
                name=name,
                label=label,
                setting_type=setting_type,
                default_value=str(value) if value else "",
                description=desc,
                options=options,
                min_val=min_val if min_val else None,
                max_val=max_val if max_val else None,
                suffix=suffix
            )
            category.settings.append(setting)

        if category.settings:
            categories.append(category)

    return categories

def parse_menu_file(filepath: Path) -> List[MenuItem]:
    """Parse menu items from main_menu.lua file."""
    items = []

    with open(filepath, 'r') as f:
        content = f.read()

    # Find the items table
    items_match = re.search(r'items\s*=\s*\{(.+?)\n\s*\}', content, re.DOTALL)
    if not items_match:
        return items

    items_block = items_match.group(1)

    # Parse each menu item: {label = "...", description = "...", ...}
    item_pattern = re.compile(r'\{[^}]+\}', re.DOTALL)

    for match in item_pattern.finditer(items_block):
        block = match.group(0)

        # Extract fields
        label_match = re.search(r'label\s*=\s*"([^"]+)"', block)
        desc_match = re.search(r'description\s*=\s*"([^"]+)"', block)
        shortcut_match = re.search(r'shortcut\s*=\s*"([^"]+)"', block)
        enabled_match = re.search(r'enabled\s*=\s*(true|false)', block)

        if label_match:
            item = MenuItem(
                label=label_match.group(1),
                description=desc_match.group(1) if desc_match else "",
                shortcut=shortcut_match.group(1) if shortcut_match else "",
                enabled=enabled_match.group(1) != 'false' if enabled_match else True
            )
            items.append(item)

    return items

def group_by_module(functions: List[LuaFunction], module_infos: Optional[Dict[str, ModuleInfo]] = None) -> Dict[str, LuaModule]:
    """Group functions by their module and apply module descriptions."""
    modules: Dict[str, LuaModule] = {}
    module_infos = module_infos or {}

    for func in functions:
        if func.module not in modules:
            # Get module info if available
            info = module_infos.get(func.module)
            modules[func.module] = LuaModule(
                name=func.module,
                brief=info.brief if info else "",
                description=info.description if info else ""
            )
        modules[func.module].functions.append(func)

    return modules

def create_function_index(functions: List[LuaFunction]) -> Dict[str, LuaFunction]:
    """Create an index of functions by their various names for cross-referencing."""
    index = {}
    for func in functions:
        # Index by full qualified name
        index[func.fqn] = func
        # Index by just function name
        index[func.name] = func
        # Index by name with () suffix
        index[f"{func.name}()"] = func
        index[f"{func.fqn}()"] = func
    return index

def create_bus_message_index(bus_messages: List[BusMessage]) -> Dict[str, BusMessage]:
    """Create an index of bus messages by their topic for cross-referencing."""
    index = {}
    for msg in bus_messages:
        # Index by full topic
        index[msg.topic] = msg
        # Index by topic with "bus:" prefix for explicit references
        index[f"bus:{msg.topic}"] = msg
        # Also index by just the last part of topic (e.g., "received" for "message/received")
        if '/' in msg.topic:
            short_name = msg.topic.split('/')[-1]
            # Only use short name if it doesn't conflict
            if short_name not in index:
                index[short_name] = msg
    return index

def linkify_references(text: str, func_index: Dict[str, LuaFunction],
                       bus_index: Dict[str, BusMessage] = None,
                       current_func: Optional[LuaFunction] = None) -> str:
    """Convert function references in text to clickable HTML links."""
    bus_index = bus_index or {}

    # Pattern to find function references like function_name() or module.function()
    pattern = r'\b((?:ez\.)?(?:\w+\.)*\w+)\(\)'

    def replace_ref(match):
        ref = match.group(1)
        # Remove ez. prefix for lookup
        lookup = ref.replace('ez.', '')

        if lookup in func_index:
            func = func_index[lookup]
            # Don't link to self
            if current_func and func.fqn == current_func.fqn:
                return match.group(0)
            return f'<a href="#{func.anchor}" class="func-ref">{match.group(0)}</a>'
        return match.group(0)

    return re.sub(pattern, replace_ref, text)

def linkify_markdown(text: str, func_index: Dict[str, LuaFunction], modules: Dict[str, LuaModule],
                     bus_index: Dict[str, BusMessage] = None,
                     current_module: Optional[str] = None) -> str:
    """Convert function/module references in text to markdown links."""
    bus_index = bus_index or {}

    # Pattern to find function references like function_name() or module.function()
    pattern = r'\b((?:ez\.)?(?:\w+\.)*\w+)\(\)'

    def replace_ref(match):
        ref = match.group(1)
        # Remove ez. prefix for lookup
        lookup = ref.replace('ez.', '')

        if lookup in func_index:
            func = func_index[lookup]
            # Link within same module uses anchor, different module uses relative path
            if current_module and func.module == current_module:
                return f'[`{match.group(0)}`](#{func.name.lower()})'
            else:
                return f'[`{match.group(0)}`](../{func.module}/#{func.name.lower()})'
        # Check if it's a module reference (without function)
        elif lookup in modules:
            return f'[`ez.{lookup}`](../{lookup}/)'
        return match.group(0)

    return re.sub(pattern, replace_ref, text)

def format_see_also_html(see_also: List[str], func_index: Dict[str, LuaFunction],
                         bus_index: Dict[str, BusMessage], current_module: str = "") -> str:
    """Format see_also list as HTML links."""
    links = []
    for ref in see_also:
        ref = ref.strip()
        # Check if it's a bus message reference (with or without "bus:" prefix)
        bus_ref = ref[4:] if ref.startswith("bus:") else ref
        if bus_ref in bus_index:
            msg = bus_index[bus_ref]
            links.append(f'<a href="#{msg.anchor}" class="bus-ref">{html.escape(msg.topic)}</a>')
        # Check if it's a function reference
        elif ref.replace('()', '') in func_index or ref in func_index:
            lookup = ref.replace('()', '').replace('ez.', '')
            if lookup in func_index:
                func = func_index[lookup]
                display = f"{func.name}()"
                if current_module and func.module == current_module:
                    links.append(f'<a href="#{func.name.lower()}" class="func-ref">{display}</a>')
                else:
                    links.append(f'<a href="../{func.module}/#{func.name.lower()}" class="func-ref">{display}</a>')
            else:
                links.append(html.escape(ref))
        else:
            links.append(html.escape(ref))
    return ', '.join(links)

def format_see_also_markdown(see_also: List[str], func_index: Dict[str, LuaFunction],
                             bus_index: Dict[str, BusMessage], modules: Dict[str, LuaModule],
                             current_module: str = "") -> str:
    """Format see_also list as markdown links."""
    links = []
    for ref in see_also:
        ref = ref.strip()
        # Check if it's a bus message reference (with or without "bus:" prefix)
        bus_ref = ref[4:] if ref.startswith("bus:") else ref
        if bus_ref in bus_index:
            msg = bus_index[bus_ref]
            # Link to bus message in the _messages section or same page if in module
            if current_module:
                links.append(f"[`{msg.topic}`](#{msg.anchor})")
            else:
                links.append(f"[`{msg.topic}`](./_messages/#{msg.anchor})")
        # Check if it's a function reference
        elif ref.replace('()', '') in func_index or ref in func_index:
            lookup = ref.replace('()', '').replace('ez.', '')
            if lookup in func_index:
                func = func_index[lookup]
                display = f"`{func.name}()`"
                if current_module and func.module == current_module:
                    links.append(f"[{display}](#{func.name.lower()})")
                else:
                    links.append(f"[{display}](../{func.module}/#{func.name.lower()})")
            else:
                links.append(f"`{ref}`")
        else:
            links.append(f"`{ref}`")
    return ', '.join(links)

def generate_lua_syntax_highlight(code: str) -> str:
    """Apply basic Lua syntax highlighting."""
    # Escape HTML first
    code = html.escape(code)

    # Keywords
    keywords = ['local', 'function', 'end', 'if', 'then', 'else', 'elseif',
                'for', 'while', 'do', 'repeat', 'until', 'return', 'break',
                'in', 'and', 'or', 'not', 'nil', 'true', 'false']
    for kw in keywords:
        code = re.sub(rf'\b({kw})\b', r'<span class="kw">\1</span>', code)

    # Strings (single and double quotes)
    code = re.sub(r'(&quot;[^&]*?&quot;|\'[^\']*?\')', r'<span class="str">\1</span>', code)

    # Comments
    code = re.sub(r'(--.*?)$', r'<span class="cmt">\1</span>', code, flags=re.MULTILINE)

    # Numbers
    code = re.sub(r'\b(\d+\.?\d*)\b', r'<span class="num">\1</span>', code)

    # Function calls (but not keywords)
    code = re.sub(r'\b([a-zA-Z_]\w*)\s*\(', r'<span class="fn">\1</span>(', code)

    return code

def generate_html(modules: Dict[str, LuaModule], bus_messages: List[BusMessage]) -> str:
    """Generate HTML documentation with professional styling."""
    all_funcs = []
    for module in modules.values():
        all_funcs.extend(module.functions)
    all_funcs.sort(key=lambda f: f.fqn)

    func_index = create_function_index(all_funcs)
    deprecated_count = sum(1 for f in all_funcs if f.is_deprecated)

    html_parts = ['''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ezOS Lua API Reference</title>
    <style>
        :root {
            --bg-primary: #ffffff;
            --bg-secondary: #f8fafc;
            --bg-code: #f1f5f9;
            --text-primary: #1e293b;
            --text-secondary: #475569;
            --text-muted: #64748b;
            --accent: #0ea5e9;
            --accent-hover: #0284c7;
            --border: #e2e8f0;
            --shadow: rgba(0, 0, 0, 0.05);
            --code-text: #0f172a;
            --func-border: #0ea5e9;
            --deprecated-bg: #fef3c7;
            --deprecated-border: #f59e0b;
            --since-bg: #dbeafe;
            --since-text: #1e40af;
            --bus-border: #10b981;
        }

        [data-theme="dark"] {
            --bg-primary: #0f172a;
            --bg-secondary: #1e293b;
            --bg-code: #1e293b;
            --text-primary: #f1f5f9;
            --text-secondary: #cbd5e1;
            --text-muted: #94a3b8;
            --accent: #38bdf8;
            --accent-hover: #7dd3fc;
            --border: #334155;
            --shadow: rgba(0, 0, 0, 0.3);
            --code-text: #e2e8f0;
            --func-border: #38bdf8;
            --deprecated-bg: #422006;
            --deprecated-border: #d97706;
            --since-bg: #1e3a5f;
            --since-text: #93c5fd;
            --bus-border: #34d399;
        }

        * { box-sizing: border-box; }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: var(--bg-primary);
            color: var(--text-primary);
            line-height: 1.7;
            margin: 0;
            padding: 0;
        }

        .header {
            background: var(--bg-secondary);
            border-bottom: 1px solid var(--border);
            padding: 24px 0;
            position: sticky;
            top: 0;
            z-index: 100;
        }

        .header-content {
            max-width: 1100px;
            margin: 0 auto;
            padding: 0 24px;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }

        .logo {
            display: flex;
            align-items: center;
            gap: 12px;
        }

        .logo-icon {
            width: 40px;
            height: 40px;
            background: linear-gradient(135deg, var(--accent), #6366f1);
            border-radius: 10px;
            display: flex;
            align-items: center;
            justify-content: center;
            color: white;
            font-weight: bold;
            font-size: 18px;
        }

        .logo-text h1 { margin: 0; font-size: 20px; font-weight: 600; }
        .logo-text span { font-size: 12px; color: var(--text-muted); }

        .header-controls {
            display: flex;
            gap: 12px;
            align-items: center;
        }

        .search-box {
            padding: 8px 16px;
            border: 1px solid var(--border);
            border-radius: 8px;
            background: var(--bg-primary);
            color: var(--text-primary);
            font-size: 14px;
            width: 220px;
        }

        .theme-toggle {
            background: var(--bg-code);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 8px 16px;
            cursor: pointer;
            color: var(--text-primary);
            font-size: 14px;
        }

        .container { max-width: 1100px; margin: 0 auto; padding: 32px 24px; }

        /* Navigation tabs */
        .nav-tabs {
            display: flex;
            gap: 8px;
            margin-bottom: 24px;
            border-bottom: 1px solid var(--border);
            padding-bottom: 12px;
        }

        .nav-tab {
            padding: 8px 20px;
            border: 1px solid var(--border);
            border-radius: 8px 8px 0 0;
            background: var(--bg-secondary);
            color: var(--text-secondary);
            cursor: pointer;
            font-weight: 500;
            text-decoration: none;
        }

        .nav-tab.active, .nav-tab:hover {
            background: var(--accent);
            color: white;
            border-color: var(--accent);
        }

        /* Introduction section */
        .intro {
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-radius: 12px;
            padding: 24px;
            margin-bottom: 32px;
        }

        .intro h2 { margin-top: 0; color: var(--accent); }
        .intro h3 { margin-top: 24px; color: var(--text-primary); }

        .intro pre {
            background: var(--bg-code);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 16px;
            overflow-x: auto;
        }

        /* Quick Reference */
        .quick-ref {
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-radius: 12px;
            padding: 24px;
            margin-bottom: 32px;
        }

        .quick-ref-title {
            font-size: 16px;
            font-weight: 600;
            margin-bottom: 16px;
            display: flex;
            align-items: center;
            gap: 8px;
        }

        .quick-ref-title span {
            background: var(--accent);
            color: white;
            font-size: 12px;
            padding: 2px 8px;
            border-radius: 12px;
        }

        .quick-ref-list {
            column-count: 3;
            column-gap: 16px;
        }

        .quick-ref-item {
            display: block;
            font-family: 'SF Mono', Consolas, monospace;
            font-size: 11px;
            padding: 2px 4px;
            color: var(--text-secondary);
            text-decoration: none;
        }

        .quick-ref-item:hover { background: var(--bg-code); color: var(--accent); }
        .quick-ref-item.deprecated { text-decoration: line-through; opacity: 0.6; }

        /* TOC */
        .toc {
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-radius: 12px;
            padding: 24px;
            margin-bottom: 40px;
        }

        .toc-title {
            font-size: 14px;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            color: var(--text-muted);
            margin-bottom: 16px;
        }

        .toc-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
            gap: 12px;
        }

        .toc a {
            display: block;
            padding: 10px 16px;
            background: var(--bg-primary);
            border: 1px solid var(--border);
            border-radius: 8px;
            color: var(--text-primary);
            text-decoration: none;
            font-weight: 500;
            font-size: 14px;
        }

        .toc a:hover { border-color: var(--accent); color: var(--accent); }

        /* Module grid for index page */
        .module-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
            gap: 16px;
        }

        .module-card {
            display: block;
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-radius: 12px;
            padding: 20px;
            text-decoration: none;
            transition: border-color 0.2s, box-shadow 0.2s;
        }

        .module-card:hover {
            border-color: var(--accent);
            box-shadow: 0 4px 16px var(--shadow);
        }

        .module-card-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 8px;
        }

        .module-card-name {
            font-size: 16px;
            font-weight: 600;
            color: var(--accent);
        }

        .module-card-count {
            background: var(--accent);
            color: white;
            font-size: 12px;
            padding: 2px 8px;
            border-radius: 12px;
        }

        .module-card-desc {
            margin: 0;
            font-size: 14px;
            color: var(--text-secondary);
            line-height: 1.5;
        }

        /* Module */
        .module { margin-bottom: 48px; }

        .module-header {
            display: flex;
            align-items: center;
            gap: 12px;
            margin-bottom: 24px;
            padding-bottom: 12px;
            border-bottom: 2px solid var(--border);
        }

        .module-header h2 { margin: 0; font-size: 24px; color: var(--accent); }

        .module-link {
            font-size: 13px;
            color: var(--text-muted);
            text-decoration: none;
            padding: 4px 10px;
            border: 1px solid var(--border);
            border-radius: 6px;
            margin-left: auto;
        }

        .module-link:hover {
            color: var(--accent);
            border-color: var(--accent);
        }

        .func-count {
            background: var(--accent);
            color: white;
            font-size: 12px;
            padding: 4px 10px;
            border-radius: 20px;
        }

        /* Module intro */
        .module-intro {
            background: var(--bg-code);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 16px 20px;
            margin-bottom: 24px;
        }

        .module-brief {
            margin: 0 0 8px 0;
            font-size: 15px;
            font-weight: 500;
            color: var(--text-primary);
        }

        .module-desc {
            margin: 0;
            font-size: 14px;
            color: var(--text-secondary);
            line-height: 1.6;
        }

        /* Function card */
        .func {
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-left: 4px solid var(--func-border);
            border-radius: 8px;
            padding: 20px;
            margin-bottom: 16px;
            scroll-margin-top: 100px;
        }

        .func:hover { box-shadow: 0 4px 16px var(--shadow); }

        .func.deprecated {
            border-left-color: var(--deprecated-border);
            background: var(--deprecated-bg);
        }

        .func-header {
            display: flex;
            align-items: flex-start;
            justify-content: space-between;
            gap: 12px;
            flex-wrap: wrap;
        }

        .sig {
            font-family: 'SF Mono', Consolas, monospace;
            font-size: 15px;
            color: var(--accent);
            font-weight: 600;
            word-break: break-word;
        }

        .badges { display: flex; gap: 8px; flex-wrap: wrap; }

        .badge {
            font-size: 11px;
            padding: 2px 8px;
            border-radius: 4px;
            font-weight: 500;
        }

        .badge-since {
            background: var(--since-bg);
            color: var(--since-text);
        }

        .badge-deprecated {
            background: var(--deprecated-border);
            color: white;
        }

        .deprecated-note {
            margin-top: 12px;
            padding: 10px 14px;
            background: rgba(245, 158, 11, 0.1);
            border: 1px solid var(--deprecated-border);
            border-radius: 6px;
            font-size: 14px;
        }

        .deprecated-note strong { color: var(--deprecated-border); }

        .desc { margin-top: 12px; color: var(--text-secondary); font-size: 15px; }

        .desc-detail {
            margin-top: 12px;
            padding: 12px 16px;
            background: var(--bg-code);
            border-left: 3px solid var(--border);
            border-radius: 0 6px 6px 0;
            color: var(--text-secondary);
            font-size: 14px;
        }

        .params { margin-top: 16px; }
        .params-title {
            font-size: 13px;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            color: var(--text-muted);
            margin-bottom: 8px;
        }

        .params-table { width: 100%; border-collapse: collapse; font-size: 14px; }

        .params-table th {
            text-align: left;
            padding: 10px 12px;
            background: var(--bg-code);
            border: 1px solid var(--border);
            color: var(--text-muted);
            font-weight: 600;
            font-size: 12px;
            text-transform: uppercase;
        }

        .params-table td {
            padding: 10px 12px;
            border: 1px solid var(--border);
            background: var(--bg-primary);
        }

        .params-table td:first-child {
            font-family: 'SF Mono', Consolas, monospace;
            color: var(--accent);
            font-weight: 600;
            white-space: nowrap;
            width: 120px;
        }

        .returns {
            margin-top: 12px;
            padding: 10px 14px;
            background: var(--bg-code);
            border-radius: 6px;
            font-size: 14px;
        }

        .returns strong { color: var(--text-muted); }

        .see-also {
            margin-top: 12px;
            font-size: 13px;
            color: var(--text-muted);
        }

        .see-also a { color: var(--accent); }

        /* Code blocks with syntax highlighting */
        pre {
            background: var(--bg-code);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 16px;
            overflow-x: auto;
            margin-top: 12px;
        }

        pre code {
            font-family: 'SF Mono', 'Fira Code', Consolas, monospace;
            font-size: 13px;
            color: var(--code-text);
            background: none;
            padding: 0;
        }

        /* Lua syntax highlighting */
        .kw { color: #c678dd; }  /* keywords */
        .str { color: #98c379; } /* strings */
        .cmt { color: #5c6370; font-style: italic; } /* comments */
        .num { color: #d19a66; } /* numbers */
        .fn { color: #61afef; }  /* function names */

        [data-theme="dark"] .kw { color: #c678dd; }
        [data-theme="dark"] .str { color: #98c379; }
        [data-theme="dark"] .cmt { color: #7f848e; }
        [data-theme="dark"] .num { color: #d19a66; }
        [data-theme="dark"] .fn { color: #61afef; }

        code {
            font-family: 'SF Mono', Consolas, monospace;
            background: var(--bg-code);
            padding: 2px 6px;
            border-radius: 4px;
            font-size: 13px;
        }

        .func-ref {
            color: var(--accent);
            text-decoration: none;
            border-bottom: 1px dashed var(--accent);
        }

        .func-ref:hover { border-bottom-style: solid; }

        /* Bus messages section */
        .bus-msg {
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-left: 4px solid var(--bus-border);
            border-radius: 8px;
            padding: 20px;
            margin-bottom: 16px;
            scroll-margin-top: 100px;
        }

        .bus-topic {
            font-family: 'SF Mono', Consolas, monospace;
            font-size: 15px;
            color: #10b981;
            font-weight: 600;
        }

        .payload {
            margin-top: 12px;
            padding: 10px 14px;
            background: var(--bg-code);
            border-radius: 6px;
            font-size: 14px;
        }

        .payload strong { color: var(--text-muted); }

        /* Collapsible cards */
        details.func { background: var(--bg-secondary); border: 1px solid var(--border);
                       border-left: 4px solid var(--accent); border-radius: 8px;
                       margin-bottom: 12px; scroll-margin-top: 100px; }
        details.func > summary { padding: 16px 20px; cursor: pointer; list-style: none;
                                 display: flex; align-items: flex-start; gap: 8px; }
        details.func > summary::-webkit-details-marker { display: none; }
        details.func > summary::before { content: '▶'; flex-shrink: 0; margin-top: 4px;
                                         font-size: 10px; transition: transform 0.2s; color: var(--text-muted); }
        details.func[open] > summary::before { transform: rotate(90deg); }
        details.func > .func-body { padding: 0 20px 20px 20px; border-top: 1px solid var(--border); }
        details.func.bus { border-left-color: var(--bus-border); }

        .func-summary { display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 12px; flex: 1; }
        .func-name { font-family: 'SF Mono', Consolas, monospace; font-weight: 600;
                     font-size: 15px; color: var(--text-primary); }
        .func-returns-hint { font-size: 13px; color: var(--text-muted); }
        .func-brief { font-size: 14px; color: var(--text-secondary); width: 100%; margin-top: 2px; }

        .footer {
            text-align: center;
            padding: 32px 24px;
            border-top: 1px solid var(--border);
            color: var(--text-muted);
            font-size: 14px;
        }

        /* Section visibility */
        .section { display: none; }
        .section.active { display: block; }

        @media (max-width: 640px) {
            .header-content { flex-direction: column; gap: 16px; }
            .toc-grid { grid-template-columns: 1fr; }
            .quick-ref-list { column-count: 2; }
            .func-header { flex-direction: column; }
        }
    </style>
</head>
<body>
<nav class="nav" style="padding: 12px 24px; background: var(--bg-secondary); border-bottom: 1px solid var(--border);">
    <a href="../../shell/" style="color: var(--accent); text-decoration: none;">← Back to Shell Guide</a>
</nav>
<header class="header">
    <div class="header-content">
        <div class="logo">
            <div class="logo-icon">ez</div>
            <div class="logo-text">
                <h1>ezOS</h1>
                <span>Lua API Reference</span>
            </div>
        </div>
        <div class="header-controls">
            <button class="theme-toggle" onclick="toggleTheme()">
                <span id="theme-icon">&#9790;</span>
            </button>
        </div>
    </div>
</header>

<div class="container">

<div class="nav-tabs">
    <a href="#" class="nav-tab active" onclick="showSection('intro-section', this); return false;">Introduction</a>
    <a href="#" class="nav-tab" onclick="showSection('api-section', this); return false;">API Reference</a>
    <a href="#" class="nav-tab" onclick="showSection('bus-section', this); return false;">Message Bus</a>
</div>

<!-- Introduction Section -->
<div id="intro-section" class="section active">
<div class="intro">
''' + INTRODUCTION.replace('\n```lua\n', '\n<pre><code>').replace('\n```\n', '</code></pre>\n').replace('```lua', '<pre><code>').replace('```', '</code></pre>') + '''
</div>
</div>

<!-- API Reference Section -->
<div id="api-section" class="section">

<p style="color: var(--text-secondary); margin-bottom: 24px;">
    ''' + str(len(all_funcs)) + f''' functions across {len(modules)} modules. Click a module to view its documentation.
</p>

<div class="module-grid">
''']

    # Module cards with links to per-module pages
    for name in sorted(modules.keys()):
        module = modules[name]
        func_count = len(module.functions)
        brief = html.escape(module.brief) if module.brief else ''
        html_parts.append(f'''
    <a href="./{name}/" class="module-card">
        <div class="module-card-header">
            <span class="module-card-name">ez.{name}</span>
            <span class="module-card-count">{func_count}</span>
        </div>
        <p class="module-card-desc">{brief}</p>
    </a>
''')

    html_parts.append('</div>\n')
    html_parts.append('</div>\n')  # End API section

    # Bus Messages Section
    html_parts.append('''
<!-- Message Bus Section -->
<div id="bus-section" class="section">
<div class="intro">
''' + BUS_INTRO + '''
</div>
''')

    if bus_messages:
        for msg in sorted(bus_messages, key=lambda m: m.topic):
            # Build collapsible card
            html_parts.append(f'<details class="func bus" id="{msg.anchor}">\n')
            html_parts.append('<summary>\n<div class="func-summary">\n')
            html_parts.append(f'<span class="func-name">{html.escape(msg.topic)}</span>\n')
            if msg.payload:
                html_parts.append(f'<span class="func-returns-hint">→ {html.escape(msg.payload)}</span>\n')
            if msg.brief:
                html_parts.append(f'<span class="func-brief">{html.escape(msg.brief)}</span>\n')
            html_parts.append('</div>\n</summary>\n')
            html_parts.append('<div class="func-body">\n')
            if msg.description:
                html_parts.append(f'<div class="desc-detail">{html.escape(msg.description)}</div>\n')
            if msg.payload:
                html_parts.append(f'<div class="payload"><strong>Payload:</strong> <code>{html.escape(msg.payload)}</code></div>\n')
            if msg.example:
                highlighted = generate_lua_syntax_highlight(msg.example)
                html_parts.append(f'<pre><code>{highlighted}</code></pre>\n')
            html_parts.append('</div>\n</details>\n')
    else:
        html_parts.append('<p style="color: var(--text-muted);">Bus message documentation not yet available. Add @bus comments to source files.</p>\n')

    html_parts.append('</div>\n')  # End bus section

    html_parts.append('''
</div>

<footer class="footer">
    ezOS Lua API Documentation &middot; Auto-generated from source
</footer>

<script>
    function toggleTheme() {
        const html = document.documentElement;
        const isDark = html.getAttribute('data-theme') === 'dark';
        html.setAttribute('data-theme', isDark ? 'light' : 'dark');
        document.getElementById('theme-icon').innerHTML = isDark ? '&#9790;' : '&#9788;';
        localStorage.setItem('theme', isDark ? 'light' : 'dark');
    }

    function showSection(sectionId, tab) {
        document.querySelectorAll('.section').forEach(s => s.classList.remove('active'));
        document.querySelectorAll('.nav-tab').forEach(t => t.classList.remove('active'));
        document.getElementById(sectionId).classList.add('active');
        tab.classList.add('active');
    }

    // Load saved theme
    (function() {
        const saved = localStorage.getItem('theme');
        const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
        const theme = saved || (prefersDark ? 'dark' : 'light');
        if (theme === 'dark') {
            document.documentElement.setAttribute('data-theme', 'dark');
            document.getElementById('theme-icon').innerHTML = '&#9788;';
        }
    })();

    // Handle anchor links
    if (window.location.hash) {
        const hash = window.location.hash.substring(1);
        if (hash.startsWith('bus-')) {
            showSection('bus-section', document.querySelectorAll('.nav-tab')[2]);
        } else {
            showSection('api-section', document.querySelectorAll('.nav-tab')[1]);
        }
    }
</script>
</body>
</html>''')

    return ''.join(html_parts)

def generate_module_html(module: LuaModule, bus_messages: List[BusMessage],
                         func_index: Dict[str, LuaFunction],
                         bus_index: Dict[str, BusMessage] = None,
                         all_modules: Dict[str, LuaModule] = None) -> str:
    """Generate standalone HTML for a single module."""
    all_modules = all_modules or {}
    bus_index = bus_index or {}

    html_parts = [f'''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ez.{module.name} - ezOS Lua API</title>
    <style>
        :root {{
            --bg-primary: #ffffff; --bg-secondary: #f8fafc; --bg-code: #f1f5f9;
            --text-primary: #1e293b; --text-secondary: #475569; --text-muted: #64748b;
            --accent: #0ea5e9; --border: #e2e8f0; --func-border: #0ea5e9; --bus-border: #10b981;
        }}
        [data-theme="dark"] {{
            --bg-primary: #0f172a; --bg-secondary: #1e293b; --bg-code: #1e293b;
            --text-primary: #f1f5f9; --text-secondary: #cbd5e1; --text-muted: #94a3b8;
            --accent: #38bdf8; --border: #334155; --func-border: #38bdf8; --bus-border: #34d399;
        }}
        * {{ box-sizing: border-box; }}
        body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
               background: var(--bg-primary); color: var(--text-primary);
               line-height: 1.7; margin: 0; padding: 24px; max-width: 900px; margin: 0 auto; }}
        a {{ color: var(--accent); text-decoration: none; }}
        a:hover {{ text-decoration: underline; }}
        h1 {{ color: var(--accent); border-bottom: 2px solid var(--border); padding-bottom: 12px; }}
        h2 {{ margin-top: 32px; color: var(--text-primary); }}
        code {{ background: var(--bg-code); padding: 2px 6px; border-radius: 4px; font-size: 14px; }}
        .module-nav {{ display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 20px;
                      padding: 12px; background: var(--bg-secondary); border-radius: 8px; }}
        .module-nav a {{ padding: 4px 10px; border-radius: 4px; font-size: 13px;
                        background: var(--bg-code); border: 1px solid var(--border); }}
        .module-nav a:hover {{ background: var(--accent); color: white; border-color: var(--accent); }}
        .module-nav a.current {{ background: var(--accent); color: white; border-color: var(--accent); }}
        pre {{ background: var(--bg-code); border: 1px solid var(--border); border-radius: 8px;
               padding: 16px; overflow-x: auto; }}
        pre code {{ background: none; padding: 0; }}
        .module-intro {{ background: var(--bg-secondary); border: 1px solid var(--border);
                        border-radius: 8px; padding: 16px 20px; margin-bottom: 24px; }}
        .module-brief {{ margin: 0 0 8px 0; font-size: 15px; font-weight: 500; }}
        .module-desc {{ margin: 0; font-size: 14px; color: var(--text-secondary); }}
        /* Collapsible function cards */
        details.func {{ background: var(--bg-secondary); border: 1px solid var(--border);
                       border-left: 4px solid var(--func-border); border-radius: 8px;
                       margin-bottom: 16px; scroll-margin-top: 20px; }}
        details.func > summary {{ padding: 16px 20px; cursor: pointer; list-style: none;
                                  display: flex; align-items: flex-start; gap: 8px; }}
        details.func > summary::-webkit-details-marker {{ display: none; }}
        details.func > summary::before {{ content: '▶'; flex-shrink: 0; margin-top: 4px;
                                         font-size: 10px; transition: transform 0.2s; color: var(--text-muted); }}
        details.func[open] > summary::before {{ transform: rotate(90deg); }}
        details.func > .func-body {{ padding: 0 20px 20px 20px; border-top: 1px solid var(--border); }}
        details.func.bus {{ border-left-color: var(--bus-border); }}
        .func-summary {{ display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 12px; flex: 1; }}
        .func-name {{ font-family: 'SF Mono', Consolas, monospace; font-size: 15px;
                     color: var(--accent); font-weight: 600; }}
        .func-returns-hint {{ font-size: 13px; color: var(--text-muted); }}
        .func-brief {{ font-size: 14px; color: var(--text-secondary); width: 100%; margin-top: 2px; }}
        .sig {{ font-family: 'SF Mono', Consolas, monospace; font-size: 15px;
               color: var(--accent); font-weight: 600; margin-bottom: 12px; }}
        .desc {{ margin-top: 12px; color: var(--text-secondary); }}
        .params-table {{ width: 100%; border-collapse: collapse; font-size: 14px; margin-top: 12px; }}
        .params-table th {{ text-align: left; padding: 8px; background: var(--bg-code);
                          border: 1px solid var(--border); font-size: 12px; }}
        .params-table td {{ padding: 8px; border: 1px solid var(--border); }}
        .params-table td:first-child {{ font-family: monospace; color: var(--accent); }}
        .returns {{ margin-top: 12px; padding: 10px 14px; background: var(--bg-code); border-radius: 6px; }}
        .see-also {{ margin-top: 12px; font-size: 14px; color: var(--text-muted); }}
        .see-also a {{ color: var(--accent); }}
        .bus-ref {{ color: #10b981; border-bottom: 1px dashed #10b981; }}
        .func-ref {{ border-bottom: 1px dashed var(--accent); }}
        .nav {{ margin-bottom: 24px; }}
        .kw {{ color: #7c3aed; }} .str {{ color: #059669; }} .cmt {{ color: #6b7280; }} .num {{ color: #0891b2; }} .fn {{ color: #2563eb; }}
    </style>
</head>
<body>
<nav class="nav"><a href="../">← Back to API Reference</a></nav>
<h1>ez.{module.name}</h1>
''']

    # Module quick links
    if all_modules:
        html_parts.append('<div class="module-nav">\n')
        for name in sorted(all_modules.keys()):
            if name == module.name:
                html_parts.append(f'<a href="../{name}/" class="current">{name}</a>\n')
            else:
                html_parts.append(f'<a href="../{name}/">{name}</a>\n')
        html_parts.append('</div>\n')

    if module.brief or module.description:
        html_parts.append('<div class="module-intro">\n')
        if module.brief:
            html_parts.append(f'<p class="module-brief">{html.escape(module.brief)}</p>\n')
        if module.description:
            desc_text = ' '.join(module.description.split())
            html_parts.append(f'<p class="module-desc">{html.escape(desc_text)}</p>\n')
        html_parts.append('</div>\n')

    # Functions - collapsible cards
    html_parts.append('<h2>Functions</h2>\n')
    for func in sorted(module.functions, key=lambda f: f.name):
        # Extract return type hint from signature if available
        returns_hint = ""
        if '->' in func.signature:
            returns_hint = func.signature.split('->')[-1].strip()

        html_parts.append(f'<details class="func" id="{func.name.lower()}">\n')
        html_parts.append('<summary>\n<div class="func-summary">\n')
        html_parts.append(f'<span class="func-name">{html.escape(func.name)}()</span>\n')
        if returns_hint:
            html_parts.append(f'<span class="func-returns-hint">→ {html.escape(returns_hint)}</span>\n')
        if func.brief:
            html_parts.append(f'<span class="func-brief">{html.escape(func.brief)}</span>\n')
        html_parts.append('</div>\n</summary>\n')

        html_parts.append('<div class="func-body">\n')
        html_parts.append(f'<div class="sig">{html.escape(func.signature)}</div>\n')

        if func.description:
            desc_text = ' '.join(func.description.split())
            desc_linked = linkify_references(html.escape(desc_text), func_index, bus_index, func)
            html_parts.append(f'<div class="desc">{desc_linked}</div>\n')

        if func.params:
            html_parts.append('<table class="params-table"><tr><th>Parameter</th><th>Description</th></tr>\n')
            for param in func.params:
                html_parts.append(f'<tr><td>{html.escape(param.name)}</td><td>{html.escape(param.description)}</td></tr>\n')
            html_parts.append('</table>\n')

        if func.returns:
            html_parts.append(f'<div class="returns"><strong>Returns:</strong> {html.escape(func.returns)}</div>\n')

        if func.see_also:
            see_html = format_see_also_html(func.see_also, func_index, bus_index, module.name)
            html_parts.append(f'<div class="see-also"><strong>See also:</strong> {see_html}</div>\n')

        if func.example:
            highlighted = generate_lua_syntax_highlight(func.example)
            html_parts.append(f'<pre><code>{highlighted}</code></pre>\n')

        html_parts.append('</div>\n</details>\n')

    # Bus messages - collapsible cards
    if bus_messages:
        html_parts.append('<h2 id="bus-messages">Bus Messages</h2>\n')
        for msg in sorted(bus_messages, key=lambda m: m.topic):
            html_parts.append(f'<details class="func bus" id="{msg.anchor}">\n')
            html_parts.append('<summary>\n<div class="func-summary">\n')
            html_parts.append(f'<span class="func-name" style="color: #10b981;">{html.escape(msg.topic)}</span>\n')
            if msg.payload:
                html_parts.append(f'<span class="func-returns-hint">payload: {html.escape(msg.payload[:50])}{"..." if len(msg.payload) > 50 else ""}</span>\n')
            if msg.brief:
                html_parts.append(f'<span class="func-brief">{html.escape(msg.brief)}</span>\n')
            html_parts.append('</div>\n</summary>\n')

            html_parts.append('<div class="func-body">\n')
            if msg.description:
                html_parts.append(f'<div class="desc">{html.escape(" ".join(msg.description.split()))}</div>\n')
            if msg.payload:
                html_parts.append(f'<div class="returns"><strong>Payload:</strong> <code>{html.escape(msg.payload)}</code></div>\n')
            if msg.see_also:
                see_html = format_see_also_html(msg.see_also, func_index, bus_index, module.name)
                html_parts.append(f'<div class="see-also"><strong>See also:</strong> {see_html}</div>\n')
            if msg.example:
                highlighted = generate_lua_syntax_highlight(msg.example)
                html_parts.append(f'<pre><code>{highlighted}</code></pre>\n')
            html_parts.append('</div>\n</details>\n')

    html_parts.append('</body></html>')
    return ''.join(html_parts)

def generate_module_markdown(module: LuaModule, bus_messages: List[BusMessage],
                             func_index: Dict[str, LuaFunction] = None,
                             bus_index: Dict[str, BusMessage] = None,
                             modules: Dict[str, LuaModule] = None) -> str:
    """Generate markdown documentation for a single module."""
    func_index = func_index or {}
    bus_index = bus_index or {}
    modules = modules or {}

    def linkify(text: str) -> str:
        if func_index and modules:
            return linkify_markdown(text, func_index, modules, bus_index, module.name)
        return text

    lines = [
        f"# ez.{module.name}",
        "",
    ]

    if module.brief:
        lines.extend([f"**{module.brief}**", ""])

    if module.description:
        lines.extend([linkify(' '.join(module.description.split())), ""])

    # Quick reference for this module
    lines.extend([
        "## Functions",
        "",
    ])

    func_rows = []
    for func in sorted(module.functions, key=lambda f: f.name):
        deprecated = " *(deprecated)*" if func.is_deprecated else ""
        func_rows.append([f"[`{func.name}`](#{func.name.lower()}){deprecated}", func.brief])

    lines.append(format_markdown_table(["Function", "Description"], func_rows))
    lines.extend(["", "---", ""])

    # Function details
    for func in sorted(module.functions, key=lambda f: f.name):
        badges = []
        if func.since:
            badges.append(f"*Since {func.since}*")
        if func.is_deprecated:
            badges.append("**DEPRECATED**")

        lines.extend([
            f"## {func.name}",
            "",
            f"```lua",
            f"{func.signature}",
            f"```",
            ""
        ])

        if badges:
            lines.append(" ".join(badges))
            lines.append("")

        if func.is_deprecated and func.deprecated:
            lines.append(f"> ⚠️ **Deprecated:** {linkify(func.deprecated)}")
            lines.append("")

        if func.brief:
            lines.extend([linkify(func.brief), ""])

        if func.description:
            lines.extend([linkify(' '.join(func.description.split())), ""])

        if func.params:
            lines.append("**Parameters:**")
            lines.append("")
            for param in func.params:
                lines.append(f"- `{param.name}` - {param.description}")
            lines.append("")

        if func.returns:
            lines.extend([f"**Returns:** {func.returns}", ""])

        if func.see_also:
            see_md = format_see_also_markdown(func.see_also, func_index, bus_index, modules, module.name)
            lines.append(f"**See also:** {see_md}")
            lines.append("")

        if func.example:
            lines.extend([
                "**Example:**",
                "```lua",
                func.example,
                "```",
                ""
            ])

    # Bus messages for this module
    module_bus_msgs = [m for m in bus_messages if m.related_module == module.name]
    if module_bus_msgs:
        lines.extend(["---", "", "## Bus Messages", ""])
        for msg in sorted(module_bus_msgs, key=lambda m: m.topic):
            lines.extend([f"### {msg.topic}", ""])
            if msg.brief:
                lines.extend([msg.brief, ""])
            if msg.description:
                lines.extend([' '.join(msg.description.split()), ""])
            if msg.payload:
                lines.append(f"**Payload:** `{msg.payload}`")
                lines.append("")
            if msg.see_also:
                see_md = format_see_also_markdown(msg.see_also, func_index, bus_index, modules, module.name)
                lines.append(f"**See also:** {see_md}")
                lines.append("")
            if msg.example:
                lines.extend([
                    "**Example:**",
                    "```lua",
                    msg.example,
                    "```",
                    ""
                ])

    return '\n'.join(lines)

def generate_index_markdown(modules: Dict[str, LuaModule], bus_messages: List[BusMessage]) -> str:
    """Generate index markdown with links to module pages."""
    total_funcs = sum(len(m.functions) for m in modules.values())

    lines = [
        "[← Back to Shell Guide](../../shell/)",
        "",
        "# ezOS Lua API Reference",
        "",
        f"> {len(modules)} modules, {total_funcs} functions",
        "",
        "## Modules",
        "",
    ]

    # Build module table with aligned columns
    module_rows = []
    for name in sorted(modules.keys()):
        module = modules[name]
        brief = module.brief if module.brief else ""
        module_rows.append([f"[ez.{name}](./{name}/)", brief, str(len(module.functions))])

    lines.append(format_markdown_table(["Module", "Description", "Functions"], module_rows))

    lines.extend(["", "---", ""])

    # Introduction content (markdown version)
    lines.extend([
        "## Getting Started",
        "",
        "### Memory Model",
        "",
        "- **Lua allocations use PSRAM** — The Lua VM allocates from the 8MB PSRAM",
        "- **Strings are immutable** — Each operation creates a new string; avoid concatenation in loops",
        "- **Tables use memory** — Empty tables take ~40 bytes; reuse tables in performance-critical code",
        "- **Garbage collection** — Runs automatically, or trigger with `ez.system.gc()`",
        "",
        "### Color Format",
        "",
        "Display functions use **RGB565** format (16-bit color). Use `ez.display.rgb(r, g, b)` to convert:",
        "",
        "```lua",
        "local red = ez.display.colors.RED",
        "local custom = ez.display.rgb(128, 64, 255)",
        "```",
        "",
        "### Best Practices",
        "",
        "1. **Prefer local variables** — Globals are slower and use more memory",
        "2. **Reuse tables** — Clear and reuse instead of creating new ones",
        "3. **Batch drawing** — Draw everything, then call `flush()` once per frame",
        "4. **Unload unused modules** — Use `unload_module()` to free memory",
        "",
    ])

    # Bus messages section
    if bus_messages:
        lines.extend([
            "---",
            "",
            "## Message Bus",
            "",
            "The message bus provides publish/subscribe communication between components.",
            "",
        ])

        bus_rows = []
        for msg in sorted(bus_messages, key=lambda m: m.topic):
            brief = msg.brief if msg.brief else ""
            bus_rows.append([f"`{msg.topic}`", brief])

        lines.append(format_markdown_table(["Topic", "Description"], bus_rows))
        lines.extend(["", "See individual module pages for bus message details.", ""])

    return '\n'.join(lines)

def generate_bus_markdown(bus_messages: List[BusMessage], func_index: Dict[str, LuaFunction] = None,
                          bus_index: Dict[str, BusMessage] = None,
                          modules: Dict[str, LuaModule] = None) -> str:
    """Generate markdown for all bus messages."""
    func_index = func_index or {}
    bus_index = bus_index or {}
    modules = modules or {}

    lines = [
        "# Message Bus Reference",
        "",
        "The message bus provides publish/subscribe communication between components.",
        "Use `ez.bus.subscribe()` to listen for events and `ez.bus.post()` to publish them.",
        "",
        "## Topics",
        "",
    ]

    # Group messages by module for better organization
    by_module = {}
    for msg in bus_messages:
        mod = msg.related_module or "other"
        if mod not in by_module:
            by_module[mod] = []
        by_module[mod].append(msg)

    for mod_name in sorted(by_module.keys()):
        mod_msgs = by_module[mod_name]
        # Add module header with link
        if mod_name in modules:
            lines.extend([f"### ez.{mod_name}", ""])
            lines.append(f"*From module [`ez.{mod_name}`](../{mod_name}/)*")
            lines.append("")
        else:
            lines.extend([f"### {mod_name}", ""])

        for msg in sorted(mod_msgs, key=lambda m: m.topic):
            lines.extend([f"#### {msg.topic}", ""])
            if msg.brief:
                lines.extend([f"**{msg.brief}**", ""])
            if msg.description:
                lines.extend([' '.join(msg.description.split()), ""])
            if msg.payload:
                lines.append(f"**Payload:** `{msg.payload}`")
                lines.append("")
            if msg.see_also:
                see_md = format_see_also_markdown(msg.see_also, func_index, bus_index, modules, "")
                lines.append(f"**See also:** {see_md}")
                lines.append("")
            if msg.example:
                lines.extend([
                    "**Example:**",
                    "```lua",
                    msg.example,
                    "```",
                    ""
                ])

    return '\n'.join(lines)

def generate_shell_guide_index(categories: List[SettingsCategory], modules: Dict[str, LuaModule],
                               menu_items: List[MenuItem] = None) -> str:
    """Generate the main index for user-facing shell documentation."""
    total_settings = sum(len(c.settings) for c in categories)
    total_funcs = sum(len(m.functions) for m in modules.values())

    lines = [
        "# ezOS Shell Guide",
        "",
        "Welcome to the ezOS Shell - a complete embedded operating system for the LilyGo T-Deck Plus.",
        "",
        "## Quick Start",
        "",
        "ezOS provides a Lua-based shell environment for interacting with the T-Deck hardware:",
        "",
        "- **Display**: 320×240 LCD with touch-optimized UI",
        "- **Keyboard**: Full QWERTY with trackball navigation",
        "- **LoRa Radio**: Mesh networking for off-grid communication",
        "- **GPS**: Location and time synchronization",
        "- **SD Card**: File storage and offline maps",
        "",
        "## Navigation",
        "",
        "- **Arrow keys** or **Trackball**: Navigate menus and lists",
        "- **Enter**: Select/confirm",
        "- **Escape** or **Q**: Go back",
        "- **Menu Hotkey** (default: LShift+RShift): Open app menu from any screen",
        "",
        "## Contents",
        "",
    ]

    contents_table = format_markdown_table(
        ["Section", "Description"],
        [
            ["[Menu Items](./menu/)", "Main menu screens and keyboard shortcuts"],
            ["[Settings Reference](./settings/)", f"All {total_settings} device settings organized by category"],
            ["[Offline Maps](./maps/)", "How to generate and use offline map tiles"],
            ["[API Reference](../development/shell/)", f"Developer documentation ({total_funcs} functions)"],
        ]
    )
    lines.extend([
        contents_table,
        "",
    ])

    # Menu items section with shortcuts
    if menu_items:
        lines.extend([
            "## Main Menu",
            "",
            "Press the **Menu Hotkey** (default: LShift+RShift) to access the main menu from any screen.",
            "Use keyboard shortcuts for quick navigation:",
            "",
        ])

        menu_rows = []
        for item in menu_items:
            shortcut = f"`{item.shortcut}`" if item.shortcut else "—"
            status = "" if item.enabled else " *(disabled)*"
            menu_rows.append([item.label + status, shortcut, item.description])

        lines.append(format_markdown_table(["Screen", "Hotkey", "Description"], menu_rows))
        lines.extend(["", ""])

    lines.extend([
        "## Settings Categories",
        "",
        "Configure your device through the Settings app. Settings are organized into these categories:",
        "",
    ])

    for cat in categories:
        lines.append(f"- **[{cat.title}](./settings/#{cat.key})**: {cat.description}")

    lines.extend([
        "",
        "## Generating Offline Maps",
        "",
        "ezOS includes an offline map viewer. To create map tiles for your region:",
        "",
        "1. Download a PMTiles file for your area from [Protomaps](https://protomaps.com/downloads/protomaps)",
        "2. Run the conversion tool:",
        "",
        "```bash",
        "cd tools/maps",
        "pip install -r requirements.txt",
        "python pmtiles_to_tdmap.py input.pmtiles -o map.tdmap",
        "```",
        "",
        "3. Copy `map.tdmap` to your SD card",
        "",
        "See the [Maps Guide](./maps/) for detailed instructions and options.",
        "",
        "## For Developers",
        "",
        "ezOS exposes a comprehensive Lua API for building applications. See the",
        "[Development API Reference](../development/shell/) for complete documentation of all",
        f"{len(modules)} modules and {total_funcs} functions.",
        "",
        "Key modules:",
        "",
    ])

    # List top modules
    for name in sorted(modules.keys())[:6]:
        module = modules[name]
        lines.append(f"- [`ez.{name}`](../development/shell/{name}/): {module.brief}")

    lines.extend([
        "",
        f"[View all {len(modules)} modules →](../development/shell/)",
        "",
    ])

    return '\n'.join(lines)

def generate_settings_reference(categories: List[SettingsCategory]) -> str:
    """Generate complete settings reference markdown."""
    total = sum(len(c.settings) for c in categories)

    lines = [
        "# Settings Reference",
        "",
        f"ezOS has {total} configurable settings organized into {len(categories)} categories.",
        "Access settings from the main menu: **Menu → Settings**.",
        "",
        "## Categories",
        "",
    ]

    cat_rows = []
    for cat in categories:
        cat_rows.append([f"[{cat.title}](#{cat.key})", str(len(cat.settings)), cat.description])

    lines.append(format_markdown_table(["Category", "Settings", "Description"], cat_rows))
    lines.extend(["", "---", ""])

    # Detailed settings per category
    for cat in categories:
        lines.extend([
            f"## {cat.title}",
            "",
            f"*{cat.description}*",
            "",
            f"**Menu path:** Settings → {cat.title}",
            "",
        ])

        for setting in cat.settings:
            lines.extend([
                f"### {setting.label}",
                "",
            ])

            # Setting metadata
            meta_parts = [f"**Type:** {setting.setting_type}"]
            if setting.default_value and setting.default_value != '""':
                default = setting.default_value
                if setting.setting_type == 'toggle':
                    default = 'On' if default == 'true' else 'Off'
                elif setting.setting_type == 'option' and setting.options:
                    try:
                        idx = int(default)
                        if 0 < idx <= len(setting.options):
                            default = setting.options[idx - 1]
                    except (ValueError, IndexError):
                        pass
                meta_parts.append(f"**Default:** {default}")

            if setting.min_val and setting.max_val:
                meta_parts.append(f"**Range:** {setting.min_val} - {setting.max_val}{setting.suffix}")

            lines.append(" | ".join(meta_parts))
            lines.append("")

            if setting.options:
                lines.append("**Options:**")
                for opt in setting.options:
                    lines.append(f"- {opt}")
                lines.append("")

            if setting.description:
                lines.extend([setting.description, ""])

            lines.append(f"*Preference key:* `{setting.name}`")
            lines.extend(["", "---", ""])

    return '\n'.join(lines)

def generate_menu_reference(menu_items: List[MenuItem]) -> str:
    """Generate the menu items reference page."""
    lines = [
        "# Menu Reference",
        "",
        "ezOS uses a main menu for navigation between screens. Access it by pressing the",
        "**Menu Hotkey** (default: LShift+RShift) from any screen.",
        "",
        "## Keyboard Shortcuts",
        "",
        "Many menu items have keyboard shortcuts for quick access. Press the shortcut key",
        "while viewing the main menu to jump directly to that screen.",
        "",
    ]

    menu_rows = []
    for item in menu_items:
        shortcut = f"`{item.shortcut}`" if item.shortcut else "—"
        status = " *(disabled)*" if not item.enabled else ""
        menu_rows.append([item.label + status, shortcut, item.description])

    lines.append(format_markdown_table(["Screen", "Hotkey", "Description"], menu_rows))

    # Detailed descriptions for each menu item
    lines.extend(["", "---", "", "## Screen Details", ""])

    menu_details = {
        "Messages": "View and compose direct messages with other nodes in the mesh network. Messages are encrypted end-to-end using the recipient's public key.",
        "Channels": "Join group messaging channels for broadcast communication. Channels can be public (#Public) or encrypted with a shared password.",
        "Contacts": "Manage your saved contacts. Add nodes you've communicated with to quickly find them later.",
        "Nodes": "View all nodes heard on the mesh network. Shows signal strength, last seen time, and distance if GPS is available.",
        "Node Info": "Display detailed information about your device including Node ID, GPS coordinates, memory usage, and radio status.",
        "Map": "Offline map viewer for navigation. Requires a TDMAP file on the SD card. See the Maps Guide for setup instructions.",
        "Packets": "Live view of raw mesh network packets. Useful for debugging and understanding network activity.",
        "Settings": "Configure all device settings including WiFi, radio parameters, display options, and hotkeys.",
        "Storage": "View disk space usage for internal flash (LittleFS) and SD card storage.",
        "Files": "Browse files on the SD card and internal storage.",
        "Diagnostics": "Access testing and diagnostic tools for hardware verification and debugging.",
        "Games": "Collection of classic games including Snake, Tetris, Pong, 2048, and more.",
    }

    for item in menu_items:
        if not item.enabled:
            continue
        lines.extend([
            f"### {item.label}",
            "",
        ])
        if item.shortcut:
            lines.append(f"**Shortcut:** `{item.shortcut}`")
            lines.append("")
        detail = menu_details.get(item.label, item.description)
        lines.extend([detail, "", "---", ""])

    # Navigation tips
    lines.extend([
        "## Navigation Tips",
        "",
        "- **Arrow keys** or **Trackball**: Move selection up/down",
        "- **Enter** or **Space**: Open selected screen",
        "- **Left/Right**: Page up/down through menu",
        "- **First letter**: Jump to item starting with that letter",
        "- **Escape** or **Q**: Go back to previous screen",
        "",
    ])

    return '\n'.join(lines)

def markdown_to_simple_html(markdown_content: str, title: str) -> str:
    """Convert markdown to simple HTML with consistent styling."""
    # Basic markdown to HTML conversion
    content = html.escape(markdown_content)

    # Headers
    content = re.sub(r'^### (.+)$', r'<h3>\1</h3>', content, flags=re.MULTILINE)
    content = re.sub(r'^## (.+)$', r'<h2>\1</h2>', content, flags=re.MULTILINE)
    content = re.sub(r'^# (.+)$', r'<h1>\1</h1>', content, flags=re.MULTILINE)

    # Bold and italic
    content = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', content)
    content = re.sub(r'\*(.+?)\*', r'<em>\1</em>', content)

    # Code blocks (must be before inline code to avoid partial matching)
    content = re.sub(r'```(\w*)\n(.*?)```', r'<pre><code>\2</code></pre>', content, flags=re.DOTALL)

    # Inline code
    content = re.sub(r'`([^`]+)`', r'<code>\1</code>', content)

    # Links
    content = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2">\1</a>', content)

    # Tables
    def convert_table(match):
        lines = match.group(0).strip().split('\n')
        if len(lines) < 2:
            return match.group(0)

        html_lines = ['<table>']
        for i, line in enumerate(lines):
            if '---' in line:
                continue
            cells = [c.strip() for c in line.split('|')[1:-1]]
            tag = 'th' if i == 0 else 'td'
            row = ''.join(f'<{tag}>{c}</{tag}>' for c in cells)
            html_lines.append(f'<tr>{row}</tr>')
        html_lines.append('</table>')
        return '\n'.join(html_lines) + '\n'

    content = re.sub(r'(\|.+\|[\n\r]+)+', convert_table, content)

    # Lists
    content = re.sub(r'^- (.+)$', r'<li>\1</li>', content, flags=re.MULTILINE)
    content = re.sub(r'(<li>.*</li>\n)+', r'<ul>\g<0></ul>', content)

    # Horizontal rules (before paragraph wrapping)
    content = re.sub(r'^---+$', '<hr>', content, flags=re.MULTILINE)

    # Paragraphs (lines not already wrapped, skip content in pre blocks)
    lines = content.split('\n')
    result = []
    in_pre = False
    for line in lines:
        if '<pre>' in line:
            in_pre = True
        if '</pre>' in line:
            in_pre = False
        if in_pre or not line.strip() or line.strip().startswith('<'):
            result.append(line)
        else:
            result.append(f'<p>{line}</p>')
    content = '\n'.join(result)

    return f'''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{html.escape(title)} - ezOS</title>
    <style>
        :root {{
            --bg: #ffffff; --bg-alt: #f8fafc; --text: #1e293b;
            --text-muted: #64748b; --accent: #0ea5e9; --border: #e2e8f0;
        }}
        @media (prefers-color-scheme: dark) {{
            :root {{
                --bg: #0f172a; --bg-alt: #1e293b; --text: #f1f5f9;
                --text-muted: #94a3b8; --accent: #38bdf8; --border: #334155;
            }}
        }}
        body {{ font-family: -apple-system, sans-serif; background: var(--bg);
               color: var(--text); max-width: 900px; margin: 0 auto; padding: 24px; line-height: 1.6; }}
        h1, h2, h3 {{ color: var(--accent); }}
        a {{ color: var(--accent); }}
        code {{ background: var(--bg-alt); padding: 2px 6px; border-radius: 4px; font-size: 14px; }}
        pre {{ background: var(--bg-alt); padding: 16px; border-radius: 8px; overflow-x: auto; }}
        pre code {{ background: none; padding: 0; }}
        table {{ width: 100%; border-collapse: collapse; margin: 16px 0; }}
        th, td {{ padding: 10px; border: 1px solid var(--border); text-align: left; }}
        th {{ background: var(--bg-alt); }}
        hr {{ border: none; border-top: 1px solid var(--border); margin: 24px 0; }}
        ul {{ padding-left: 24px; }}
        .nav {{ margin-bottom: 24px; }}
    </style>
</head>
<body>
<nav class="nav"><a href="../">← Back</a></nav>
{content}
</body>
</html>'''

def generate_maps_guide() -> str:
    """Generate the offline maps documentation."""
    return """# Offline Maps Guide

ezOS includes an offline map viewer for navigation without cellular or internet connectivity.
Maps are stored as `.tdmap` files on the SD card.

## Quick Start

1. **Download source data**: Get a PMTiles file from [Protomaps](https://protomaps.com/downloads/protomaps)
2. **Convert to TDMAP format**:
   ```bash
   cd tools/maps
   pip install -r requirements.txt
   python pmtiles_to_tdmap.py input.pmtiles -o map.tdmap
   ```
3. **Copy to SD card**: Place `map.tdmap` in the root of your SD card
4. **Open in ezOS**: Navigate to **Menu → Map Viewer**

## Conversion Options

### Basic Usage

```bash
python pmtiles_to_tdmap.py input.pmtiles -o output.tdmap
```

### Limit to Specific Region

```bash
python pmtiles_to_tdmap.py input.pmtiles \\
    --bounds 4.0,52.0,5.5,52.5 \\
    --zoom 10,14 \\
    -o netherlands.tdmap
```

Options:
- `--bounds WEST,SOUTH,EAST,NORTH`: Limit to bounding box (decimal degrees)
- `--zoom MIN,MAX`: Zoom levels to include (default: all available)
- `--resume`: Resume interrupted conversion

### Large Regions

For large areas, the conversion saves checkpoints every 500 tiles. If interrupted,
simply run the same command again to resume.

## TDMAP Format

The TDMAP format is optimized for the ESP32's limited memory:

- **8-color semantic palette**: Land, water, parks, buildings, roads, railways
- **RLE compression**: Typically 5-20x smaller than raw pixels
- **Binary search index**: Fast tile lookup without loading entire file
- **Labels**: Place names with coordinates and zoom ranges

## File Size Estimates

| Region | Zoom Levels | Approximate Size |
|--------|-------------|------------------|
| City | 10-16 | 5-20 MB |
| Country | 8-14 | 50-200 MB |
| Continent | 6-12 | 200-500 MB |

## Map Settings

Configure the map viewer in **Settings → Map**:

- **Theme**: Light or dark color scheme
- **Pan Speed**: Trackball movement sensitivity

## Troubleshooting

### "No map file found"
Ensure `map.tdmap` is in the root of the SD card and the card is properly inserted.

### Slow loading
Large map files may take a few seconds to index on first load. The index is cached
for subsequent accesses.

### Missing areas
Check your `--bounds` parameters. The conversion only includes tiles that intersect
the bounding box.

## See Also

- [tools/maps/README.md](../../tools/maps/README.md) - Conversion tool documentation
- [Settings Reference](./settings/) - Map viewer settings
"""

def main():
    script_dir = Path(__file__).parent
    project_root = script_dir.parent
    src_dir = project_root / 'src'
    data_dir = project_root / 'data'
    docs_dir = project_root / 'docs' / 'manuals' / 'development' / 'shell'
    user_docs_dir = project_root / 'docs' / 'manuals' / 'shell'

    print(f"Scanning {src_dir} for Lua bindings...")

    binding_files = find_binding_files(src_dir)
    if not binding_files:
        print("No binding files found!")
        sys.exit(1)

    print(f"Found {len(binding_files)} binding files")

    all_functions = []
    all_bus_messages = []
    all_module_infos: Dict[str, ModuleInfo] = {}

    for filepath in binding_files:
        print(f"  Parsing {filepath.name}...")
        functions, bus_msgs, module_infos = parse_binding_file(filepath)
        all_functions.extend(functions)
        all_bus_messages.extend(bus_msgs)
        for module_info in module_infos:
            all_module_infos[module_info.name] = module_info
        print(f"    Found {len(functions)} functions, {len(bus_msgs)} bus messages")

    if not all_functions:
        print("No documented functions found. Add @lua doc comments to binding files.")
        sys.exit(1)

    modules = group_by_module(all_functions, all_module_infos)
    func_index = create_function_index(all_functions)
    bus_index = create_bus_message_index(all_bus_messages)
    deprecated_count = sum(1 for f in all_functions if f.is_deprecated)

    print(f"\nTotal: {len(all_functions)} functions in {len(modules)} modules")
    print(f"  Deprecated: {deprecated_count}")
    print(f"  Bus messages: {len(all_bus_messages)}")

    # Parse settings from Lua file
    settings_file = data_dir / 'scripts' / 'ui' / 'screens' / 'settings_category.lua'
    settings_categories = []
    if settings_file.exists():
        print(f"\nParsing settings from {settings_file.name}...")
        settings_categories = parse_settings_file(settings_file)
        total_settings = sum(len(c.settings) for c in settings_categories)
        print(f"  Found {total_settings} settings in {len(settings_categories)} categories")

    # Parse menu items from main_menu.lua
    menu_file = data_dir / 'scripts' / 'ui' / 'screens' / 'main_menu.lua'
    menu_items = []
    if menu_file.exists():
        print(f"Parsing menu items from {menu_file.name}...")
        menu_items = parse_menu_file(menu_file)
        print(f"  Found {len(menu_items)} menu items")

    docs_dir.mkdir(parents=True, exist_ok=True)
    user_docs_dir.mkdir(parents=True, exist_ok=True)

    # ==========================================
    # Generate Development API Documentation
    # ==========================================
    print("\n--- Development Documentation ---")

    # Generate main index markdown
    index_md_path = docs_dir / 'index.md'
    with open(index_md_path, 'w') as f:
        f.write(generate_index_markdown(modules, all_bus_messages))
    print(f"Generated {index_md_path}")

    # Generate per-module markdown and HTML in subdirs
    for name in sorted(modules.keys()):
        module = modules[name]
        module_dir = docs_dir / name
        module_dir.mkdir(parents=True, exist_ok=True)

        # Find bus messages for this module based on related_module property
        module_bus_msgs = [m for m in all_bus_messages if m.related_module == name]

        # Markdown with cross-references
        md_path = module_dir / 'index.md'
        with open(md_path, 'w') as f:
            f.write(generate_module_markdown(module, module_bus_msgs, func_index, bus_index, modules))
        print(f"Generated {md_path}")

        # Per-module HTML with navigation to other modules
        html_path = module_dir / 'index.html'
        with open(html_path, 'w') as f:
            f.write(generate_module_html(module, module_bus_msgs, func_index, bus_index, modules))
        print(f"Generated {html_path}")

    # Generate bus messages markdown (in _messages to avoid conflict with bus module)
    messages_dir = docs_dir / '_messages'
    messages_dir.mkdir(parents=True, exist_ok=True)
    bus_md_path = messages_dir / 'index.md'
    with open(bus_md_path, 'w') as f:
        f.write(generate_bus_markdown(all_bus_messages, func_index, bus_index, modules))
    print(f"Generated {bus_md_path}")

    # Generate main HTML (all-in-one for easy viewing)
    html_path = docs_dir / 'index.html'
    with open(html_path, 'w') as f:
        f.write(generate_html(modules, all_bus_messages))
    print(f"Generated {html_path}")

    # ==========================================
    # Generate User-Facing Shell Documentation
    # ==========================================
    print("\n--- User Documentation ---")

    # Main shell guide index
    shell_content = generate_shell_guide_index(settings_categories, modules, menu_items)
    shell_index_path = user_docs_dir / 'index.md'
    with open(shell_index_path, 'w') as f:
        f.write(shell_content)
    print(f"Generated {shell_index_path}")
    with open(user_docs_dir / 'index.html', 'w') as f:
        f.write(markdown_to_simple_html(shell_content, "ezOS Shell Guide"))
    print(f"Generated {user_docs_dir / 'index.html'}")

    # Menu reference
    menu_dir = user_docs_dir / 'menu'
    menu_dir.mkdir(parents=True, exist_ok=True)
    menu_content = generate_menu_reference(menu_items)
    menu_md_path = menu_dir / 'index.md'
    with open(menu_md_path, 'w') as f:
        f.write(menu_content)
    print(f"Generated {menu_md_path}")
    with open(menu_dir / 'index.html', 'w') as f:
        f.write(markdown_to_simple_html(menu_content, "Menu Reference"))
    print(f"Generated {menu_dir / 'index.html'}")

    # Settings reference
    settings_dir = user_docs_dir / 'settings'
    settings_dir.mkdir(parents=True, exist_ok=True)
    settings_content = generate_settings_reference(settings_categories)
    settings_md_path = settings_dir / 'index.md'
    with open(settings_md_path, 'w') as f:
        f.write(settings_content)
    print(f"Generated {settings_md_path}")
    with open(settings_dir / 'index.html', 'w') as f:
        f.write(markdown_to_simple_html(settings_content, "Settings Reference"))
    print(f"Generated {settings_dir / 'index.html'}")

    # Maps guide
    maps_dir = user_docs_dir / 'maps'
    maps_dir.mkdir(parents=True, exist_ok=True)
    maps_content = generate_maps_guide()
    maps_md_path = maps_dir / 'index.md'
    with open(maps_md_path, 'w') as f:
        f.write(maps_content)
    print(f"Generated {maps_md_path}")
    with open(maps_dir / 'index.html', 'w') as f:
        f.write(markdown_to_simple_html(maps_content, "Offline Maps Guide"))
    print(f"Generated {maps_dir / 'index.html'}")

    print(f"\n✓ Documentation generated successfully!")
    print(f"  Development docs: {docs_dir}")
    print(f"  User docs: {user_docs_dir}")

if __name__ == '__main__':
    main()
