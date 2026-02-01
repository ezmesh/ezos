#!/usr/bin/env python3
"""
Lua API Documentation Generator for T-Deck OS

Parses C++ binding files and generates markdown and HTML documentation.
Doc comments use the following format in the source:

    // @lua ez.module.function_name(arg1, arg2) -> return_type
    // @brief Short description of the function
    // @param arg1 Description of first argument
    // @param arg2 Description of second argument
    // @return Description of return value
    // @example
    // local result = ez.module.function_name("hello", 42)
    // @end
"""

import os
import re
import sys
from pathlib import Path
from dataclasses import dataclass, field
from typing import List, Dict, Optional
import html

# Functions to exclude from documentation (deprecated/removed features)
EXCLUDED_FUNCTIONS = set()

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

    @property
    def fqn(self) -> str:
        """Return fully qualified name like module.function"""
        return f"{self.module}.{self.name}"

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
        # Supports: "ez.module.func()", "module.func()", "func()"
        sig_match = re.match(r'(?:(\w+)\.)?(\w+)\.(\w+)\((.*?)\)(?:\s*->\s*(.+))?', signature)
        if sig_match:
            # prefix.module.function or module.function
            module = sig_match.group(2)
            name = sig_match.group(3)
        else:
            # Try simple function: func()
            sig_match = re.match(r'(\w+)\((.*?)\)(?:\s*->\s*(.+))?', signature)
            if sig_match:
                module = "global"
                name = sig_match.group(1)
            else:
                continue

        # Skip excluded functions
        if name in EXCLUDED_FUNCTIONS:
            continue

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

def get_all_fqns_sorted(modules: Dict[str, LuaModule]) -> List[LuaFunction]:
    """Get all functions sorted alphabetically by FQN."""
    all_funcs = []
    for module in modules.values():
        all_funcs.extend(module.functions)
    return sorted(all_funcs, key=lambda f: f.fqn)

def generate_markdown(modules: Dict[str, LuaModule]) -> str:
    """Generate markdown documentation."""
    all_funcs = get_all_fqns_sorted(modules)

    lines = [
        "# T-Deck OS Lua API Reference",
        "",
        "> Auto-generated from source code",
        "",
        "## Quick Reference (All Methods)",
        "",
        "| Method | Description |",
        "|--------|-------------|"
    ]

    # Quick reference table
    for func in all_funcs:
        brief = func.brief[:60] + "..." if len(func.brief) > 60 else func.brief
        anchor = f"#{func.module}-{func.name}".lower()
        lines.append(f"| [`{func.fqn}`]({anchor}) | {brief} |")

    lines.extend(["", "---", "", "## Table of Contents", ""])

    # TOC by module
    for name in sorted(modules.keys()):
        lines.append(f"- [ez.{name}](#{name})")
    lines.append("")

    # Modules
    for name in sorted(modules.keys()):
        module = modules[name]
        lines.extend([
            f"## {name}",
            "",
            f"### ez.{name}",
            ""
        ])

        if module.description:
            lines.extend([module.description, ""])

        for func in sorted(module.functions, key=lambda f: f.name):
            anchor = f"{name}-{func.name}".lower()
            lines.extend([
                f"#### <a name=\"{anchor}\"></a>{func.name}",
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
                lines.append("")
                lines.append("| Parameter | Description |")
                lines.append("|-----------|-------------|")
                for param in func.params:
                    lines.append(f"| `{param.name}` | {param.description} |")
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
    """Generate HTML documentation with professional styling and dark mode toggle."""
    all_funcs = get_all_fqns_sorted(modules)

    html_parts = ['''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>T-Deck OS Lua API Reference</title>
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
        }

        * { box-sizing: border-box; }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', sans-serif;
            background: var(--bg-primary);
            color: var(--text-primary);
            line-height: 1.7;
            margin: 0;
            padding: 0;
            transition: background-color 0.3s, color 0.3s;
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
            max-width: 1000px;
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

        .logo-text h1 {
            margin: 0;
            font-size: 20px;
            font-weight: 600;
            color: var(--text-primary);
        }

        .logo-text span {
            font-size: 12px;
            color: var(--text-muted);
        }

        .theme-toggle {
            background: var(--bg-code);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 8px 16px;
            cursor: pointer;
            color: var(--text-primary);
            font-size: 14px;
            display: flex;
            align-items: center;
            gap: 8px;
            transition: all 0.2s;
        }

        .theme-toggle:hover {
            border-color: var(--accent);
        }

        .container {
            max-width: 1000px;
            margin: 0 auto;
            padding: 32px 24px;
        }

        /* Quick Reference Index */
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
            color: var(--text-primary);
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
            font-family: 'SF Mono', 'Fira Code', 'Consolas', monospace;
            font-size: 11px;
            padding: 2px 4px;
            border-radius: 3px;
            color: var(--text-secondary);
            text-decoration: none;
            transition: all 0.15s;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
        }

        .quick-ref-item:hover {
            background: var(--bg-code);
            color: var(--accent);
        }

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
            transition: all 0.2s;
        }

        .toc a:hover {
            border-color: var(--accent);
            color: var(--accent);
            transform: translateY(-1px);
            box-shadow: 0 4px 12px var(--shadow);
        }

        .module {
            margin-bottom: 48px;
        }

        .module-header {
            display: flex;
            align-items: center;
            gap: 12px;
            margin-bottom: 24px;
            padding-bottom: 12px;
            border-bottom: 2px solid var(--border);
        }

        .module-header h2 {
            margin: 0;
            font-size: 24px;
            color: var(--accent);
        }

        .func-count {
            background: var(--accent);
            color: white;
            font-size: 12px;
            padding: 4px 10px;
            border-radius: 20px;
            font-weight: 500;
        }

        .func {
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-left: 4px solid var(--func-border);
            border-radius: 8px;
            padding: 20px;
            margin-bottom: 16px;
            transition: all 0.2s;
        }

        .func:hover {
            box-shadow: 0 4px 16px var(--shadow);
        }

        /* Offset anchors to account for sticky header */
        .func[id], .module-header h2[id] {
            scroll-margin-top: 100px;
        }

        .sig {
            font-family: 'SF Mono', 'Fira Code', 'Consolas', monospace;
            font-size: 15px;
            color: var(--accent);
            font-weight: 600;
            word-break: break-word;
        }

        .desc {
            margin-top: 12px;
            color: var(--text-secondary);
            font-size: 15px;
        }

        .params {
            margin-top: 16px;
        }

        .params-title {
            font-size: 13px;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            color: var(--text-muted);
            margin-bottom: 8px;
        }

        .params-table {
            width: 100%;
            border-collapse: collapse;
            font-size: 14px;
        }

        .params-table th {
            text-align: left;
            padding: 10px 12px;
            background: var(--bg-code);
            border: 1px solid var(--border);
            color: var(--text-muted);
            font-weight: 600;
            font-size: 12px;
            text-transform: uppercase;
            letter-spacing: 0.3px;
        }

        .params-table td {
            padding: 10px 12px;
            border: 1px solid var(--border);
            background: var(--bg-primary);
        }

        .params-table td:first-child {
            font-family: 'SF Mono', 'Fira Code', 'Consolas', monospace;
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

        .returns strong {
            color: var(--text-muted);
        }

        pre {
            background: var(--bg-code);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 16px;
            overflow-x: auto;
            margin-top: 12px;
        }

        pre code {
            font-family: 'SF Mono', 'Fira Code', 'Consolas', monospace;
            font-size: 13px;
            color: var(--code-text);
            background: none;
            padding: 0;
        }

        code {
            font-family: 'SF Mono', 'Fira Code', 'Consolas', monospace;
            background: var(--bg-code);
            padding: 2px 6px;
            border-radius: 4px;
            font-size: 13px;
        }

        .footer {
            text-align: center;
            padding: 32px 24px;
            border-top: 1px solid var(--border);
            color: var(--text-muted);
            font-size: 14px;
        }

        @media (max-width: 640px) {
            .header-content { flex-direction: column; gap: 16px; }
            .toc-grid { grid-template-columns: 1fr; }
            .quick-ref-list { column-count: 2; }
        }

        @media (max-width: 400px) {
            .quick-ref-list { column-count: 1; }
        }
    </style>
</head>
<body>
<header class="header">
    <div class="header-content">
        <div class="logo">
            <div class="logo-icon">TD</div>
            <div class="logo-text">
                <h1>T-Deck OS</h1>
                <span>Lua API Reference</span>
            </div>
        </div>
        <button class="theme-toggle" onclick="toggleTheme()">
            <span id="theme-icon">&#9790;</span>
            <span id="theme-label">Dark Mode</span>
        </button>
    </div>
</header>

<div class="container">

<!-- Quick Reference Index -->
<div class="quick-ref">
    <div class="quick-ref-title">Quick Reference <span>''' + str(len(all_funcs)) + ''' methods</span></div>
    <div class="quick-ref-list">
''']

    # Quick reference sorted list with tooltips
    for func in all_funcs:
        anchor = f"{func.module}-{func.name}".lower()
        tooltip = html.escape(func.brief) if func.brief else ""
        html_parts.append(f'        <a class="quick-ref-item" href="#{anchor}" title="{tooltip}">{html.escape(func.fqn)}</a>\n')

    html_parts.append('''    </div>
</div>

<div class="toc">
    <div class="toc-title">Modules</div>
    <div class="toc-grid">
''')

    # TOC
    for name in sorted(modules.keys()):
        func_count = len(modules[name].functions)
        html_parts.append(f'        <a href="#{name}">ez.{name} <span style="opacity:0.5">({func_count})</span></a>\n')
    html_parts.append('    </div>\n</div>\n')

    # Modules
    for name in sorted(modules.keys()):
        module = modules[name]
        func_count = len(module.functions)
        html_parts.append(f'''
<div class="module">
    <div class="module-header">
        <h2 id="{name}">ez.{name}</h2>
        <span class="func-count">{func_count} functions</span>
    </div>
''')

        for func in sorted(module.functions, key=lambda f: f.name):
            anchor = f"{func.module}-{func.name}".lower()
            html_parts.append(f'    <div class="func" id="{anchor}">\n')
            html_parts.append(f'        <div class="sig">{html.escape(func.signature)}</div>\n')

            if func.brief:
                html_parts.append(f'        <div class="desc">{html.escape(func.brief)}</div>\n')

            if func.params:
                html_parts.append('        <div class="params">\n')
                html_parts.append('            <div class="params-title">Parameters</div>\n')
                html_parts.append('            <table class="params-table">\n')
                html_parts.append('                <tr><th>Parameter</th><th>Description</th></tr>\n')
                for param in func.params:
                    html_parts.append(f'                <tr><td>{html.escape(param.name)}</td><td>{html.escape(param.description)}</td></tr>\n')
                html_parts.append('            </table>\n')
                html_parts.append('        </div>\n')

            if func.returns:
                html_parts.append(f'        <div class="returns"><strong>Returns:</strong> {html.escape(func.returns)}</div>\n')

            if func.example:
                html_parts.append(f'        <pre><code>{html.escape(func.example)}</code></pre>\n')

            html_parts.append('    </div>\n')

        html_parts.append('</div>\n')

    html_parts.append('''
</div>

<footer class="footer">
    T-Deck OS Lua API Documentation &middot; Auto-generated from source
</footer>

<script>
    function toggleTheme() {
        const html = document.documentElement;
        const isDark = html.getAttribute('data-theme') === 'dark';
        html.setAttribute('data-theme', isDark ? 'light' : 'dark');
        document.getElementById('theme-icon').innerHTML = isDark ? '&#9790;' : '&#9788;';
        document.getElementById('theme-label').textContent = isDark ? 'Dark Mode' : 'Light Mode';
        localStorage.setItem('theme', isDark ? 'light' : 'dark');
    }

    // Load saved theme preference
    (function() {
        const saved = localStorage.getItem('theme');
        const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
        const theme = saved || (prefersDark ? 'dark' : 'light');
        if (theme === 'dark') {
            document.documentElement.setAttribute('data-theme', 'dark');
            document.getElementById('theme-icon').innerHTML = '&#9788;';
            document.getElementById('theme-label').textContent = 'Light Mode';
        }
    })();
</script>
</body>
</html>''')

    return ''.join(html_parts)

def main():
    # Find project root
    script_dir = Path(__file__).parent
    project_root = script_dir.parent
    src_dir = project_root / 'src'
    docs_dir = project_root / 'docs' / 'manuals' / 'development' / 'shell'

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
    print(f"(Excluding {len(EXCLUDED_FUNCTIONS)} deprecated functions)")

    # Generate documentation
    docs_dir.mkdir(parents=True, exist_ok=True)

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
