# Icon Generation Tool

This tool generates icons for T-Deck OS from text prompts.

## Structure

```
tools/icons/
├── prompts/
│   ├── base.txt              # Base style prompt (crystal/glass aesthetic)
│   └── icons/                # Individual icon prompts
│       ├── messages.txt
│       ├── channels.txt
│       └── ...
├── output/
│   └── svg/                  # Generated SVG files
├── generate.py               # Generation and conversion script
└── README.md
```

## Usage

### List available icons
```bash
python generate.py list
```

### Generate SVGs
Use Claude Code to generate SVG icons based on the prompts:
```bash
python generate.py generate
```
This prints the combined prompts. Ask Claude Code to generate the SVGs.

### Convert to RGB565
After SVG files are in `output/svg/`, convert them:
```bash
python generate.py convert
```

This creates RGB565 files in `data/icons/{size}x{size}/`.

## Requirements

For conversion:
```bash
pip install cairosvg pillow
```

## Icon Format

- SVG source: 32x32 viewBox
- Output: RGB565 binary (big-endian)
- Transparency: Magenta (0xF81F) marks transparent pixels
- Sizes generated: 24x24, 32x32
