#!/usr/bin/env python3
"""
Lua API Documentation Generator for T-Deck OS

Parses C++ binding files and generates markdown and HTML documentation.
Doc comments use the following format in the source:

    // @lua tdeck.module.function_name(arg1, arg2) -> return_type
    // @brief Short description of the function
    // @param arg1 Description of first argument
    // @param arg2 Description of second argument
    // @return Description of return value
    // @example
    // local result = tdeck.module.function_name("hello", 42)
    // @end
"""

import os
import re
import sys
from pathlib import Path
from dataclasses import dataclass, field
from typing import List, Dict, Optional
import html

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
    params: List[LuaParam] = field(default_factory=list)
    returns: str = ""
    example: str = ""

@dataclass
class LuaModule:
    name: str
    description: str = ""
    functions: List[LuaFunction] = field(default_factory=list)

def parse_binding_file(filepath: Path) -> List[LuaFunction]:
    """Parse a C++ binding file for Lua documentation comments."""
    functions = []

    with open(filepath, 'r') as f:
        content = f.read()

    # Pattern to find doc blocks
    # Matches: // @lua ... followed by other @-tagged lines
    doc_pattern = re.compile(
        r'// @lua\s+(.+?)\s*\n'
        r'((?:// @\w+.*\n)*)',
        re.MULTILINE
    )

    for match in doc_pattern.finditer(content):
        signature = match.group(1).strip()
        doc_block = match.group(2)

        # Parse module and function name from signature
        # e.g., "tdeck.system.millis() -> integer"
        sig_match = re.match(r'tdeck\.(\w+)\.(\w+)\((.*?)\)(?:\s*->\s*(.+))?', signature)
        if not sig_match:
            continue

        module = sig_match.group(1)
        name = sig_match.group(2)
        args = sig_match.group(3) or ""
        ret_type = sig_match.group(4) or ""

        func = LuaFunction(
            module=module,
            name=name,
            signature=signature
        )

        # Parse doc block lines
        in_example = False
        example_lines = []

        for line in doc_block.split('\n'):
            line = line.strip()
            if not line.startswith('//'):
                continue
            line = line[2:].strip()

            if line.startswith('@brief'):
                func.brief = line[6:].strip()
            elif line.startswith('@param'):
                param_match = re.match(r'@param\s+(\w+)\s+(.*)', line)
                if param_match:
                    func.params.append(LuaParam(
                        name=param_match.group(1),
                        description=param_match.group(2)
                    ))
            elif line.startswith('@return'):
                func.returns = line[7:].strip()
            elif line.startswith('@example'):
                in_example = True
            elif line.startswith('@end'):
                in_example = False
                func.example = '\n'.join(example_lines)
            elif in_example:
                example_lines.append(line)

        functions.append(func)

    return functions

def find_binding_files(src_dir: Path) -> List[Path]:
    """Find all Lua binding C++ files."""
    bindings_dir = src_dir / 'lua' / 'bindings'
    if not bindings_dir.exists():
        return []
    return list(bindings_dir.glob('*_bindings.cpp'))

def group_by_module(functions: List[LuaFunction]) -> Dict[str, LuaModule]:
    """Group functions by their module."""
    modules: Dict[str, LuaModule] = {}

    for func in functions:
        if func.module not in modules:
            modules[func.module] = LuaModule(name=func.module)
        modules[func.module].functions.append(func)

    return modules

def generate_markdown(modules: Dict[str, LuaModule]) -> str:
    """Generate markdown documentation."""
    lines = [
        "# T-Deck OS Lua API Reference",
        "",
        "> Auto-generated from source code",
        "",
        "## Table of Contents",
        ""
    ]

    # TOC
    for name in sorted(modules.keys()):
        lines.append(f"- [tdeck.{name}](#{name})")
    lines.append("")

    # Modules
    for name in sorted(modules.keys()):
        module = modules[name]
        lines.extend([
            f"## {name}",
            "",
            f"### tdeck.{name}",
            ""
        ])

        if module.description:
            lines.extend([module.description, ""])

        for func in sorted(module.functions, key=lambda f: f.name):
            lines.extend([
                f"#### {func.name}",
                "",
                f"```lua",
                f"{func.signature}",
                f"```",
                ""
            ])

            if func.brief:
                lines.extend([func.brief, ""])

            if func.params:
                lines.append("**Parameters:**")
                for param in func.params:
                    lines.append(f"- `{param.name}`: {param.description}")
                lines.append("")

            if func.returns:
                lines.extend([f"**Returns:** {func.returns}", ""])

            if func.example:
                lines.extend([
                    "**Example:**",
                    "```lua",
                    func.example,
                    "```",
                    ""
                ])

    return '\n'.join(lines)

def generate_html(modules: Dict[str, LuaModule]) -> str:
    """Generate HTML documentation."""
    html_parts = ['''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>T-Deck OS Lua API Reference</title>
    <style>
        :root { --bg: #1a1a2e; --fg: #eee; --accent: #00d4ff; --code-bg: #16213e; --border: #0f3460; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: var(--bg); color: var(--fg); line-height: 1.6; margin: 0; padding: 20px; }
        .container { max-width: 900px; margin: 0 auto; }
        h1 { color: var(--accent); border-bottom: 2px solid var(--accent); padding-bottom: 10px; }
        h2 { color: var(--accent); margin-top: 40px; }
        h3 { color: #ff6b6b; }
        code { font-family: 'Fira Code', monospace; background: var(--code-bg); padding: 2px 6px; border-radius: 3px; }
        pre { background: var(--code-bg); border: 1px solid var(--border); border-radius: 5px; padding: 15px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        .func { background: var(--code-bg); border-left: 3px solid var(--accent); padding: 10px 15px; margin: 10px 0; }
        .sig { font-family: monospace; color: var(--accent); font-weight: bold; }
        .desc { margin-top: 5px; color: #ccc; }
        .params { margin: 10px 0; padding-left: 20px; }
        .toc { background: var(--code-bg); padding: 20px; border-radius: 5px; margin: 20px 0; }
        .toc a { color: var(--fg); text-decoration: none; margin-right: 20px; }
        .toc a:hover { color: var(--accent); }
    </style>
</head>
<body>
<div class="container">
<h1>T-Deck OS Lua API Reference</h1>
<p><em>Auto-generated from source code</em></p>

<div class="toc">
<strong>Modules:</strong><br>
''']

    # TOC
    for name in sorted(modules.keys()):
        html_parts.append(f'<a href="#{name}">tdeck.{name}</a>\n')
    html_parts.append('</div>\n')

    # Modules
    for name in sorted(modules.keys()):
        module = modules[name]
        html_parts.append(f'<h2 id="{name}">tdeck.{name}</h2>\n')

        for func in sorted(module.functions, key=lambda f: f.name):
            html_parts.append('<div class="func">\n')
            html_parts.append(f'<div class="sig">{html.escape(func.signature)}</div>\n')

            if func.brief:
                html_parts.append(f'<div class="desc">{html.escape(func.brief)}</div>\n')

            if func.params:
                html_parts.append('<div class="params"><strong>Parameters:</strong><ul>\n')
                for param in func.params:
                    html_parts.append(f'<li><code>{html.escape(param.name)}</code>: {html.escape(param.description)}</li>\n')
                html_parts.append('</ul></div>\n')

            if func.returns:
                html_parts.append(f'<div><strong>Returns:</strong> {html.escape(func.returns)}</div>\n')

            if func.example:
                html_parts.append(f'<pre><code>{html.escape(func.example)}</code></pre>\n')

            html_parts.append('</div>\n')

    html_parts.append('''
<hr>
<p style="text-align: center; color: #666;">Auto-generated Lua API Documentation</p>
</div>
</body>
</html>''')

    return ''.join(html_parts)

def main():
    # Find project root
    script_dir = Path(__file__).parent
    project_root = script_dir.parent
    src_dir = project_root / 'src'
    docs_dir = project_root / 'docs'

    print(f"Scanning {src_dir} for Lua bindings...")

    # Find and parse binding files
    binding_files = find_binding_files(src_dir)
    if not binding_files:
        print("No binding files found!")
        sys.exit(1)

    print(f"Found {len(binding_files)} binding files")

    all_functions = []
    for filepath in binding_files:
        print(f"  Parsing {filepath.name}...")
        functions = parse_binding_file(filepath)
        all_functions.extend(functions)
        print(f"    Found {len(functions)} documented functions")

    if not all_functions:
        print("No documented functions found. Add @lua doc comments to binding files.")
        sys.exit(1)

    # Group by module
    modules = group_by_module(all_functions)
    print(f"\nTotal: {len(all_functions)} functions in {len(modules)} modules")

    # Generate documentation
    docs_dir.mkdir(exist_ok=True)

    md_path = docs_dir / 'LUA_API_GENERATED.md'
    with open(md_path, 'w') as f:
        f.write(generate_markdown(modules))
    print(f"\nGenerated {md_path}")

    html_path = docs_dir / 'lua_api_generated.html'
    with open(html_path, 'w') as f:
        f.write(generate_html(modules))
    print(f"Generated {html_path}")

if __name__ == '__main__':
    main()
