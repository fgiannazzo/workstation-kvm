# Switchboard

A macOS menu bar utility for desk switching: drives the LG DualUp 28MQ780's picture-by-picture
mode over DDC/CI and the monitor's USB HID bridge, talks to an ESP32 controller for the HDMI and
USB switches, and exposes every action and macro to a Stream Deck.

## Status

Tracer bullet 1 of 7 (`docs/BRIEF.md`, section 6). Reads only; no hardware write exists yet.

What works today:

- `DDCKit`: DDC/CI over the video cable through the private IOAVService API (`VideoCableDDC`),
  display enumeration by EDID name (never by index), pure packet encoders and reply decoder
  tested against the byte vectors in `docs/DESIGN.md`, settle-and-double-dump reads
  (`StableReader`), and `FakeDDC` for tests.
- `Devices`: `LGDualUp.readState()` reads PBP (VCP 0xD7) and the main input (VCP 0xF5).
- `SwitchboardCore`: the shared value types (`SwitchboardState`, `ControllerState`, ...).
- `switchboardctl monitor list` and `switchboardctl monitor read`.

Next: `LGUSBBridge` and `monitor pbp on|off` with verify-after-write (tracer bullet 2), then the
state store, actions and macros, the menu bar app, the local API, the ESP32 client and the
Stream Deck plugin. See `docs/BRIEF.md` for the specification and `docs/DESIGN.md` for the
architecture.

## Requirements

- Apple Silicon Mac running macOS 15 or later (built on macOS 26 with Swift 6.4).
- Xcode 26 or later, selected with `xcode-select` (the Command Line Tools alone hit a SwiftPM bug
  with Swift Testing macros, see `docs/DESIGN.md`, "Toolchain"). No `.xcodeproj`: everything is
  SwiftPM.
- No App Store distribution (the DDC transport uses private IOKit entry points).

## Build

```bash
swift build && swift test     # or: make build && make test
```

Tests never touch hardware: they run against `FakeDDC` with the brief's byte vectors. `make`
selects Xcode's toolchain for you when Xcode is installed but `xcode-select` still points at the
Command Line Tools.

## Usage

```bash
swift run switchboardctl monitor list
swift run switchboardctl monitor read [--display SDQHD] [--json]
swift run switchboardctl --help
```

`monitor list` prints every external display with its EDID name, numeric serial (hex), serial
string when present, and manufacturer/product code. `monitor read` selects the display whose
EDID name contains `--display` (default `SDQHD`, the LG DualUp), reads 0xD7 and 0xF5 twice
0.5 s apart and reports only the values that agree:

```
display: LG SDQHD  serial 0x0001E240
0xD7 PBP: 1 (off)
0xF5 main input: 1 (HDMI 1)
```

A code that could not be read stably prints `unknown (unreadable)`; it is never defaulted.
`--json` prints the same as an object (`pbp`, `mainInput`, `raw`).

Exit codes: 0 ok, 1 error, 2 display not found.

Hardware checks are manual and live in `docs/HARDWARE-CHECKLIST.md`.

## Licence

MIT, see `LICENSE`.

## Stream Deck plugin

`StreamDeckPlugin/` holds the official Stream Deck plugin (TypeScript, Elgato SDK): a Run key that fires any macro or action through the local API, and a State tile that shows live state from `/events`. Build, install and troubleshooting steps are in [`docs/STREAMDECK-PLUGIN.md`](docs/STREAMDECK-PLUGIN.md).
