# Switchboard

A macOS menu bar utility for desk switching: drives the LG DualUp 28MQ780's picture-by-picture
mode over DDC/CI and the monitor's USB HID bridge, talks to an ESP32 controller for the HDMI and
USB switches, and exposes every action and macro to a Stream Deck.

Status: bootstrapping. See `docs/BRIEF.md` for the specification and `docs/DESIGN.md` for the
architecture. Tracer bullets land one pull request at a time.

## Requirements

- Apple Silicon Mac running macOS 15 or later (built on macOS 26 with the Swift 6.4 Command Line Tools).
- No Xcode needed; no App Store distribution (the DDC transport uses private IOKit entry points).

## Build

```bash
swift build && swift test
```

## Licence

MIT, see `LICENSE`.

## Stream Deck plugin

`StreamDeckPlugin/` holds the official Stream Deck plugin (TypeScript, Elgato SDK): a Run key that fires any macro or action through the local API, and a State tile that shows live state from `/events`. Build, install and troubleshooting steps are in [`docs/STREAMDECK-PLUGIN.md`](docs/STREAMDECK-PLUGIN.md).
