# TiltBar

A macOS menu bar app that shows your [Tilt](https://tilt.dev) resource status at a glance.

<p align="center">
  <img src="docs/tilt-logo.png" width="128" alt="Tilt Logo">
</p>

## What it looks like

**All resources healthy:**

<img src="docs/tilt-logo.png" width="18"> ← Just the green Tilt logo in your menu bar

**Resources building/errors:**

<img src="docs/tilt-logo.png" width="18"> ⚪️2 🟢5 🔴1 ← Gray/red logo + status counts

**Click the icon to open menu:**
```
┌─────────────────────────────────────┐
│ Status: Connected - 28 ok           │
├─────────────────────────────────────┤
│ Open Tilt in Browser         ⌘O     │
│ Quit                         ⌘Q     │
└─────────────────────────────────────┘
```

## Features

- 🟢 **Dynamic Tilt logo** - Green when all good, gray when building, red on errors
- 📊 **Real-time updates** - No polling, streams directly from Tilt
- 🎯 **Clean display** - Just the logo when everything is green
- 🔄 **Auto-reconnect** - Handles Tilt restarts automatically
- 🚫 **Menu bar only** - No dock icon

## Quick Start

### Requirements

- macOS 13.0+
- [Tilt CLI](https://docs.tilt.dev/install.html) installed
- Xcode Command Line Tools: `xcode-select --install`

### Setup

```bash
# Start Tilt in your project
cd your-tilt-project
tilt up

# In another terminal, clone and setup this app
git clone <repo-url>
cd tiltbar

# Download Tilt icons and build
make setup
make build

# Run the app
make run
```

That's it! The Tilt logo will appear in your menu bar.

## Usage

**Status Display:**
- 🟢 Green logo only = All resources healthy
- Icon + counts = Issues present (e.g., "⚪️2 🟢5 🔴1")

**Menu:**
- Open Tilt in Browser
- Reconnect Now
- Quit

## Troubleshooting

**"Tilt CLI not found"**
- Run `which tilt` to verify Tilt is installed
- Install: https://docs.tilt.dev/install.html

**"Cannot connect"**
- Ensure Tilt is running: `tilt up`
- Test CLI: `tilt get uiresource`

**"No icons"**
- Run `make setup` to download icons from Tilt

## Development

See `Makefile` for all available commands. Key files:
- `main.swift` - App entry point
- `AppDelegate.swift` - Menu bar UI
- `TiltClient.swift` - Streams from `tilt get uiresource -w`
- `Models.swift` - Data structures

Code includes detailed comments explaining implementation.

## License

Apache 2.0
