#!/usr/bin/env python3
"""
Sync icons to the data folder based on usage in code.

Scans Lua scripts and C++ code for icon references, then copies
only the used icons to the data/icons folder.

Usage:
    python sync_icons.py <icons_png_dir> [--size 24] [--dry-run]

Icon references are detected by patterns like:
    - tdeck.display.draw_icon("category/name", ...)
    - load_icon("category/name")
    - icon = "category/name"
"""

import os
import re
import sys
import shutil
import argparse
from pathlib import Path

# Patterns to find icon references in code
ICON_PATTERNS = [
    # Lua: draw_icon("category/name", ...) or draw_icon('category/name', ...)
    r'draw_icon\s*\(\s*["\']([^"\']+)["\']',
    # Lua: icon = "category/name"
    r'icon\s*=\s*["\']([^"\']+)["\']',
    # Lua: load_icon("category/name")
    r'load_icon\s*\(\s*["\']([^"\']+)["\']',
    # Generic: any string that looks like an icon path (category/name format)
    r'["\']([a-z]+/[a-z0-9_-]+)["\']',
]

def find_icon_references(src_dir):
    """Scan source files for icon references."""
    src_dir = Path(src_dir)
    icons = set()

    # Scan Lua files
    for lua_file in src_dir.rglob("*.lua"):
        content = lua_file.read_text(errors='ignore')
        for pattern in ICON_PATTERNS:
            matches = re.findall(pattern, content, re.IGNORECASE)
            icons.update(matches)

    # Scan C++ files
    for ext in ["*.cpp", "*.h", "*.hpp"]:
        for cpp_file in src_dir.rglob(ext):
            content = cpp_file.read_text(errors='ignore')
            for pattern in ICON_PATTERNS:
                matches = re.findall(pattern, content, re.IGNORECASE)
                icons.update(matches)

    return icons

def find_available_icons(icons_dir, size):
    """Find all available icons at the specified size."""
    icons_dir = Path(icons_dir)
    size_dir = icons_dir / f"{size}x{size}"

    if not size_dir.exists():
        return {}

    available = {}
    for png in size_dir.rglob("*.png"):
        # Build icon ID: category/name
        category = png.parent.name
        name = png.stem
        icon_id = f"{category}/{name}"
        available[icon_id] = png

    return available

def sync_icons(icons_dir, data_dir, src_dir, size, dry_run=False):
    """Sync used icons to data directory."""
    icons_dir = Path(icons_dir)
    data_dir = Path(data_dir)
    src_dir = Path(src_dir)

    # Find referenced icons
    print(f"Scanning {src_dir} for icon references...")
    referenced = find_icon_references(src_dir)
    print(f"Found {len(referenced)} icon references")

    # Find available icons
    print(f"Scanning {icons_dir} for available icons at {size}x{size}...")
    available = find_available_icons(icons_dir, size)
    print(f"Found {len(available)} available icons")

    # Determine which icons to copy
    to_copy = []
    missing = []
    unused = []

    for icon_id in referenced:
        if icon_id in available:
            to_copy.append((icon_id, available[icon_id]))
        else:
            # Check if it's a valid icon reference (has / separator)
            if '/' in icon_id:
                missing.append(icon_id)

    for icon_id in available:
        if icon_id not in referenced:
            unused.append(icon_id)

    # Report
    print()
    print(f"Icons to sync: {len(to_copy)}")

    if missing:
        print(f"\nWARNING: {len(missing)} referenced icons not found:")
        for icon_id in sorted(missing)[:10]:
            print(f"  - {icon_id}")
        if len(missing) > 10:
            print(f"  ... and {len(missing) - 10} more")

    if unused:
        print(f"\nNote: {len(unused)} available icons not used in code")

    # Copy icons
    if not dry_run and to_copy:
        output_dir = data_dir / "icons"
        output_dir.mkdir(parents=True, exist_ok=True)

        print(f"\nCopying {len(to_copy)} icons to {output_dir}...")
        for icon_id, src_path in to_copy:
            category, name = icon_id.split('/', 1)
            dest_dir = output_dir / category
            dest_dir.mkdir(parents=True, exist_ok=True)
            dest_path = dest_dir / f"{name}.png"

            shutil.copy2(src_path, dest_path)
            print(f"  {icon_id}")

        print(f"\nSynced {len(to_copy)} icons")
    elif dry_run:
        print("\nDry run - no files copied")

    return {
        'synced': len(to_copy),
        'missing': len(missing),
        'unused': len(unused)
    }

def main():
    parser = argparse.ArgumentParser(description="Sync icons to data folder")
    parser.add_argument("icons_dir", help="Directory containing converted PNG icons")
    parser.add_argument("--data-dir", default="data",
                       help="Data directory for LittleFS (default: data)")
    parser.add_argument("--src-dir", default=".",
                       help="Source directory to scan (default: current dir)")
    parser.add_argument("--size", type=int, default=24,
                       help="Icon size to sync (default: 24)")
    parser.add_argument("--dry-run", action="store_true",
                       help="Show what would be synced without copying")
    parser.add_argument("--list-unused", action="store_true",
                       help="List all unused icons")

    args = parser.parse_args()

    icons_dir = Path(args.icons_dir)
    if not icons_dir.exists():
        print(f"Error: Icons directory not found: {icons_dir}")
        sys.exit(1)

    result = sync_icons(
        icons_dir,
        args.data_dir,
        args.src_dir,
        args.size,
        args.dry_run
    )

    if args.list_unused:
        available = find_available_icons(icons_dir, args.size)
        referenced = find_icon_references(args.src_dir)
        print("\nUnused icons:")
        for icon_id in sorted(available.keys()):
            if icon_id not in referenced:
                print(f"  {icon_id}")

if __name__ == "__main__":
    main()
