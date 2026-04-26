# ezOS

A complete embedded operating system for the **LilyGo T-Deck Plus** (ESP32-S3 with LoRa), featuring encrypted mesh networking, offline maps, and a Lua-scripted user interface.

<p align="center">
  <img src="docs/screenshots/main-menu.png" alt="Main Menu" width="240"/>
  <img src="docs/screenshots/map-viewer.png" alt="Map Viewer" width="240"/>
  <img src="docs/screenshots/mesh-chat.png" alt="Mesh Chat" width="240"/>
</p>

> 🚧 **Early development.** APIs, on-disk formats, and the UI framework change between commits. Expect breaking changes, missing features, and rough edges. Not yet suitable for daily-driver or production use. Pin to a released tag if you want a stable build.

## Download & Flash

> ⚠️ **Warning:** This firmware has only been tested on the **T-Deck Plus**. Use at your own risk — no warranty or guarantee is provided.

**Easiest method** - Use the web flasher (no software install required):

1. Download the latest `ezos-vX.X.X-full.bin` from [Releases](../../releases/latest)
2. Open the [MeshCore Web Flasher](https://flasher.meshcore.co/)
3. Connect your T-Deck Plus via USB and flash

[![Download Latest](https://img.shields.io/github/v/release/ezmesh/ezos?label=Download&style=for-the-badge)](../../releases/latest)

## Features

- 📡 **Mesh Networking** - MeshCore protocol with Ed25519 signatures and AES-256-GCM encryption
- 💬 **Channel Chat** - Public and encrypted group channels
- 🔒 **Direct Messages** - Private encrypted messaging
- 🗺️ **Offline Maps** - OpenStreetMap tiles with city/town labels
- 📍 **GPS Integration** - Location sharing with mesh nodes
- 👥 **Contact Management** - Save and organize mesh contacts
- 🎮 **Games** - 2048, Tetris, Pong, Poker, Blackjack, Snake, Solitaire, Sudoku
- 🎨 **Customizable UI** - Themes, wallpapers, icon packs
- 🖥️ **Lua Shell** - Scriptable interface with full API access

## Make It Yours

The entire user interface is written in **Lua** - no C++ or complex build tools required. All hardware is exposed through simple Lua modules, so you can completely reshape the device to fit your needs.

**What you can customize:**
- Create new screens and apps
- Modify the main menu and navigation
- Build custom widgets and overlays
- Add new games or utilities
- Change themes, colors, and layouts
- Automate tasks with background services

**Available Lua modules:**

| Module | Description |
|--------|-------------|
| `ez.display` | Drawing, text, shapes, bitmaps |
| `ez.keyboard` | Key events, trackball input |
| `ez.mesh` | Send/receive messages, node discovery |
| `ez.radio` | LoRa configuration, signal strength |
| `ez.gps` | Location, speed, satellites |
| `ez.storage` | SD card files, preferences |
| `ez.audio` | Tones and melodies |
| `ez.system` | Time, memory, battery, sleep |
| `ez.crypto` | Hashing, encryption, signatures |

📖 For more information on the Lua API, please visit our [documentation site](https://ezmesh.github.io/ezos/manual/).

**Getting started:**

1. Edit `.lua` files under `lua/` in this repo. Scripts are embedded into the firmware during the build process.

Note: The issue is related to the documentation site design, which is not part of the README. Therefore, no changes were made to the README content itself, but a link to the documentation site was added for clarity.