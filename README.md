# Switchboard

A macOS menu bar utility for desk switching: drives the LG DualUp 28MQ780's picture-by-picture
mode over DDC/CI and the monitor's USB HID bridge, talks to an ESP32 controller for the HDMI and
USB switches, and exposes every action and macro to a Stream Deck.

## Status

Tracer bullets 1, 2, 6 and 7 of 7 (`docs/BRIEF.md`, section 6) are in. The hardware write path is
exactly two commands wide (PBP on over the USB bridge, PBP off over the video cable); the only
network writes go to the ESP32 controller (or its mock).

What works today:

- `DDCKit`: DDC/CI over the video cable through the private IOAVService API (`VideoCableDDC`),
  the monitor's USB HID bridge (`LGUSBBridge`, write-only, paired to the display by EDID serial),
  software re-enumeration of the bridge (`USBReenumerator`), display enumeration by EDID name
  (never by index), pure packet encoders and reply decoder tested against the byte vectors in
  `docs/DESIGN.md`, settle-and-double-dump reads (`StableReader`), and `FakeDDC` for tests.
- `Devices`: the `LGDualUpCommand` whitelist (`pbpOn`: 0xD7 = 0 over the USB bridge; `pbpOff`:
  0xD7 = 1 over the video cable) and `LGDualUp.perform`, which writes, waits 4 s for the link to
  re-train, reads 0xD7 back twice over the video cable and reports `verified` only when both
  reads agree with the expectation. `LGDualUp.readState()` reads PBP (0xD7) and the main input
  (0xF5).
- `SwitchboardCore`: the shared value types (`SwitchboardState`, `ControllerState`, ...).
- `switchboardctl monitor list|read|pbp on|pbp off|bridge list|bridge reset`.
- `TinyHTTP`: a small HTTP/1.1 server on Network.framework with server-sent events, shared by the
  controller mock and (later) the local API.
- `ESP32Kit`: `ESP32Client` (the `ControllerClient` for the ESP32 contract, with a reconnecting
  event stream), `ESP32Discovery` (mDNS `_switchboard._tcp`), `MockESP32` (the contract served from
  memory) and `ContractTest` (the checks both this repo and the firmware repo run). The contract is
  in [`docs/ESP32-CONTRACT.md`](docs/ESP32-CONTRACT.md).
- `switchboardctl controller ...`: talk to the controller, run the mock, run the contract test.

Next: the state store, actions and macros (tracer bullet 3, where `hdmi.*` and `usb.*` get wired
to `ESP32Kit`), then the menu bar app and the local API. See `docs/BRIEF.md` for the specification
and `docs/DESIGN.md` for the architecture.

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

Tests never touch hardware: they run against `FakeDDC` and a fake HID device with the brief's
byte vectors, and against `MockESP32` on loopback for everything network. `make` selects Xcode's
toolchain for you when Xcode is installed but `xcode-select` still points at the Command Line Tools.

## Usage

```bash
swift run switchboardctl monitor list
swift run switchboardctl monitor read [--display SDQHD] [--json]
swift run switchboardctl monitor pbp on|off [--display SDQHD] [--json] [--dry-run]
swift run switchboardctl monitor bridge list
swift run switchboardctl monitor bridge reset
swift run switchboardctl --help
```

The ESP32 controller (`docs/ESP32-CONTRACT.md`). Point the commands at it with
`--url http://host:port`, `export SWITCHBOARD_CONTROLLER_URL=http://host:port`, or `--discover`
(first `_switchboard._tcp` service on the LAN, `--timeout 3`); `--json` prints JSON:

```bash
swift run switchboardctl controller state
swift run switchboardctl controller hdmi lg4k 2            # pulses the LG 4K's OREI switch
swift run switchboardctl controller hdmi lg4k 1 --resync   # correct the assumed input, no pulse
swift run switchboardctl controller usb 2
swift run switchboardctl controller events                 # one line per state, until Ctrl-C
swift run switchboardctl controller discover               # list controllers found over mDNS
swift run switchboardctl controller contract-test          # exit 0 when every check passes
swift run switchboardctl controller mock [--port 48700] [--host 127.0.0.1] [--advertise]
```

`controller mock` runs `MockESP32` until Ctrl-C and prints each request, so the Stream Deck plugin
and the firmware can be developed without the board; `--advertise` publishes it over mDNS and binds
`0.0.0.0` unless `--host` says otherwise. Against a real controller `contract-test` moves the
LG 4K input and the USB port away and back (see the contract doc).

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

`monitor pbp on` writes 0xD7 = 0 over the USB HID bridge (the only transport that turns PBP on);
`monitor pbp off` writes 0xD7 = 1 over the video cable (the only transport that turns it off).
Both then wait 4 s and read 0xD7 back over the video cable:

```
transport: USB bridge (SDQHD)
writing 0xD7 = 0, then waiting 4.0 seconds for the link to settle
verified: 0xD7 = 0 (on)
```

The write alone is never reported as success. `UNVERIFIED: 0xD7 read back 1 (off)` or
`UNVERIFIED: 0xD7 unreadable` exit 3. `--dry-run` prints the exact bytes that would go out (the
two 64-byte HID reports for `on`, the 6-byte DDC packet for `off`) and touches nothing.
`--json` prints the `WriteOutcome` (`command`, `transport`, `expected`, `observed`, `verified`,
`reading`). After a USB-triggered split the Studio's half comes up at 1920 x 1080; that is
BetterDisplay's job, not this tool's.

`monitor bridge list` prints the LG HID interfaces present (product id, product string, usage
page, max output report size, serial); the serial must match the DualUp in `monitor list`.
`monitor bridge reset` re-enumerates the bridge when it has gone quiet.

Exit codes: 0 ok, 1 error, 2 display not found, 3 write unverified, 4 USB bridge not found,
5 USB bridge busy (another client, typically a browser's WebUSB client, holds it exclusively),
6 controller unreachable (`controller` commands).

Hardware checks are manual and live in `docs/HARDWARE-CHECKLIST.md`.

## Hardware rules

The only writes in this codebase are the two `LGDualUpCommand` cases. Adding one needs a verified
fact in `docs/BRIEF.md` first. Never 0xF4 on source 0x50, never 0x60, no probing, no scanning.
Every write is verified by a video-cable read. See `CLAUDE.md` and `docs/DESIGN.md`.

## Licence

MIT, see `LICENSE`.

## Stream Deck plugin

`StreamDeckPlugin/` holds the official Stream Deck plugin (TypeScript, Elgato SDK): a Run key that fires any macro or action through the local API, and a State tile that shows live state from `/events`. Build, install and troubleshooting steps are in [`docs/STREAMDECK-PLUGIN.md`](docs/STREAMDECK-PLUGIN.md).
