# Brief: Switchboard, a macOS menu bar utility for desk switching

Working name: **Switchboard** (rename freely). New repository at `~/Code/switchboard`. Owner: Felipe. Written 2026-10-11 from a working prototype in `~/Code/dualup`, which is the reference implementation and the source of every protocol fact below.

## 1. What it is

A macOS menu bar app, Swift and SwiftUI, running on the Mac Studio (Apple Silicon, macOS 26). It owns three things:

1. **The LG DualUp 28MQ780 monitor**, over two transports: DDC/CI on the video cable and the monitor's USB HID bridge. Today it must switch picture-by-picture (PBP) on and off and report state. Input selection and the other LG codes come later.
2. **An ESP32 controller, a separate upcoming project**, which pulses the select buttons of the OREI 2x1 HDMI 2.1 switches (one per display) and drives the ATEN US3344I 4x4 USB switch over RS-485. The app talks to it over the LAN. This brief fixes the contract so both sides can be built against a mock.
3. **Commands for a Stream Deck**: every action and every macro is callable from a Stream Deck key, and state is available for informational tiles. A macro chains actions into one shot, for example "guest": PBP on, USB to port 2. The app also has virtual controls so none of this needs a Stream Deck.

Hard constraints: nothing is ever installed on the guest machines. Value only flows through this app and the ESP32. No App Store distribution, because the DDC transport uses private IOKit entry points.

## 2. Read these first

All in `~/Code/dualup`, in this order:

- `dualup.py`: the command set, the config shape, scenes, the discovery and probe flows, the settle-and-double-dump technique for DDC reads.
- `ddcvcp.m`: video-cable DDC through the private `IOAVService` API. Read, write, capabilities string, the LG 0x50 source-address variant, display selection by EDID name.
- `lgusb.m`: the USB HID bridge. Device matching, the 64-byte framing, the `uset` fire-and-forget write, and the probe commands that proved the bridge never answers reads.
- `usbreset.c`: re-enumerating the bridge from software.
- `dualup.json`: the verified mapping for 0xD7 and the two scenes.
- `edid_decode.py` and `edid_patch.py` in the session scratchpad are optional context on the EDID side.

Port the behaviour, not the code. The prototype is Python plus Objective-C; the app is Swift with a small C or Objective-C target for the private API calls.

## 3. Verified facts the code must encode

### Displays and paths

| Display | Studio path | Guest path | DDC |
|---|---|---|---|
| LG DualUp 28MQ780 (EDID name `LG SDQHD`, 2560 × 2880) | HDMI 1, via a plain USB-C-to-HDMI dongle and an OREI 2x1 switch; USB upstream also on the Studio | DisplayPort, pinned as the PBP sub input in the OSD | video cable: yes; USB bridge: write-only |
| LG HDR 4K | Cable Matters 48 Gbps USB-C-to-HDMI 2.1 cable and an OREI 2x1 | OREI input 2 | yes |
| Samsung Odyssey G80SD | native HDMI 2.1 port and an OREI 2x1 | OREI input 2 | refuses DDC entirely |

The Cable Matters cable rewrites EDID to standard CTA formats and dropped the DualUp's native timing; a plain dongle passes EDID verbatim. The OREI switches pass EDID and DDC verbatim. Keep the DualUp on the dongle.

### Video-cable DDC (reference `ddcvcp.m`)

- Enumerate `DCPAVServiceProxy` services with `Location == External`, create an `IOAVServiceRef`, read the EDID with `IOAVServiceCopyEDID` to name the display. Never select by index: order changes when a display re-enumerates.
- Write: `IOAVServiceWriteI2C(service, 0x37, src, bytes)` with `src` 0x51 (standard) and bytes `84 03 code hi lo chk`; read request `82 01 code chk` followed by a 12-byte `IOAVServiceReadI2C`. Checksum is XOR over `0x6E, src, bytes`. Reply layout: byte 2 = 0x02, byte 3 = result code, byte 4 = code, bytes 6-7 = max, bytes 8-9 = current.
- Capabilities string: request `83 F3 offset_hi offset_lo chk`, read 64-byte fragments until a zero-length one. The DualUp reports `model(MQ750)` and manufacturer codes F4 F5 F6 F7 F8 F9 FA FB FD FE FF plus 4D 4E 4F 15.
- LG side channel: same packets with `src` 0x50. It accepts writes and never answers reads. Only 0xD7 may ever be sent there, and today it changes nothing. **Never write 0xF4 on 0x50**: a published report ties that command to a bricked LG on another model.
- Reads are unreliable for manufacturer codes and for 0x60. After any mode change the link re-trains: wait about 4 s, then take two dumps and keep only codes that agree. Treat an unreadable code as unknown, never as changed.

### The DualUp's PBP code, 0xD7

| Direction | Transport | Write | Read-back on the video cable |
|---|---|---|---|
| PBP on (stacked split, each half a 2560 × 1440 display) | USB bridge only | 0 | 0 |
| PBP off | video cable only | 1 | 1 |

The opposite value on each transport is accepted on the wire and ignored. Values 2 to 16, 32, 64 and 128 do nothing on either transport. 0xF5 reads the main input (1 = HDMI 1, 2 = HDMI 2) and flips on a main/sub swap. The sub input is not readable or writable by any known code; it stays pinned in the OSD. The Studio's half comes up at 1920 × 1080 after a USB-triggered split; the app should not try to fix that, BetterDisplay does.

### USB HID bridge (reference `lgusb.m`)

- Device: vendor 0x043E, product 0x9A39, product string "LG Monitor Controls", one HID interface on usage page 0xFF00, 64-byte input, output and feature reports, no report IDs. Its serial equals the monitor's EDID serial, which is how to pair bridge and display.
- Packet: `08 01 55 03 LEN 00 03 37` then a DDC packet `51 (0x80|n) data… chk` with the same XOR checksum; LEN is the DDC packet length. For a VCP set, data is `03 code hi lo`. Send it as `IOHIDDeviceSetReport(device, output, reportID 8, all 64 bytes)`, which is exactly what hidapi produces for the gist that documented this; the un-numbered form with report ID 0 and the stripped form both fail. Follow it with the same packet modified as byte1 = 02, byte3 = 04, byte4 = 0B, byte6 = 0B. Expect no reply; verify through the video-cable read.
- If the bridge goes quiet, `usbreset.c` re-enumerates it with `USBDeviceReEnumerate`. The Arc browser holds WebUSB device clients on it; harmless so far.

### OREI 8K 2x1 HDMI switches

No control port and no EDID settings. A short press of the select button toggles the input; a 3 to 5 s press toggles auto/manual mode. Run them in manual mode and pulse the button. State is not readable, so the ESP32 tracks assumed state, and the UI must offer a one-click correction.

### ATEN US3344I

RS-485 on a 5-pin terminal block, 38400 8N1, DIP-selected 422/485. Commands end with CR: `sw` (next port), `sw p01` to `sw p04`, `usb p0x` (port status), `info`. Replies `Command OK` or `Command Incorrect`. This one is readable, so its state is authoritative.

## 4. Architecture

Swift package with these targets, plus one app target:

- **`DDCKit`**: `DDCTransport` protocol; `VideoCableDDC` (IOAVService, via a C target `IOAVServiceShim` declaring the private functions); `LGUSBBridge` (IOHIDManager, write-only); `FakeDDC` for tests. Packet encoders are pure functions with tests against the byte vectors in this brief.
- **`Devices`**: `LGDualUp` with the verified table above as a declarative whitelist. A write that is not in the whitelist is a compile-time impossibility, not a runtime check.
- **`ESP32Kit`**: client for the contract in section 5, plus `MockESP32` (a tiny local HTTP server) used by tests and by the app when no controller is configured.
- **`Actions`**: action registry (`monitor.pbp.on`, `monitor.pbp.off`, `monitor.read`, `hdmi.select(display, input)`, `hdmi.resync(display, input)`, `usb.select(port)`, `delay(ms)`, `notify(text)`), macro model (ordered steps, optional verify step, abort on failure), macro store as JSON in `~/Library/Application Support/Switchboard/`.
- **`StateStore`**: one observable model: PBP state, main input, USB port, assumed HDMI input per display, controller reachability, last error. Sources: video-cable reads on a timer and after actions, ESP32 events, ATEN `info`.
- **`LocalAPI`**: HTTP on `127.0.0.1` with a bearer token stored in the keychain; `GET /state`, `GET /actions`, `GET /macros`, `POST /run/{id}`, `GET /events` (server-sent events). Also a URL scheme `switchboard://run/{id}` and a CLI `switchboardctl` that calls the API. These are what a Stream Deck uses in phase 1 without a plugin: the "Website" action for keys, and a `.command` wrapper the app can generate.
- **App**: `MenuBarExtra` with a status glyph; popover with state, virtual controls (one button per action and macro), a macro editor (list builder, no scripting), settings (controller address, token, polling interval, which display is the DualUp), and a log. Launch at login.

Phase 2, separate package: an official Stream Deck plugin (TypeScript, Elgato SDK) with a key action that runs an id and a tile action that renders state from `/events`.

## 5. ESP32 contract (build the mock first)

mDNS `_switchboard._tcp`, HTTP and JSON, no auth on the LAN for now (document it as a known gap).

- `GET /state` → `{ "hdmi": { "dualup": 1, "lg4k": 1, "samsung": 1 }, "usb": { "port": 1, "source": "aten" }, "uptime": 123 }`. HDMI values are assumed state; `usb.port` comes from the ATEN `info` reply.
- `POST /hdmi/{display}/select` body `{ "input": 1 }` → pulses until assumed state matches, returns new state. `POST /hdmi/{display}/resync` body `{ "input": 1 }` sets assumed state without pulsing.
- `POST /usb/select` body `{ "port": 2 }` → sends `sw p02`, reads back with `usb p02`, returns state.
- `GET /events` → server-sent events with the same state object on every change.

Display ids are `dualup`, `lg4k`, `samsung`. The firmware is another repo; this app ships the mock and a contract test that both repos run.

## 6. Tracer bullets, one pull request each

1. Repo skeleton, package layout, `DDCKit` with `VideoCableDDC` and packet tests; `switchboardctl monitor read` prints the DualUp's 0xD7 and 0xF5. Verification command: `swift build && swift test`.
2. `LGUSBBridge` plus `monitor pbp on` and `monitor pbp off`, each verified by the video-cable read. Reproduces today's result end to end.
3. `StateStore`, `Actions`, macro store and runner; `switchboardctl run guest`.
4. Menu bar app with virtual controls, state, settings, macro editor, launch at login.
5. `LocalAPI`, URL scheme, generated Stream Deck wrappers; document the key setup.
6. `ESP32Kit` with the mock and contract tests; `hdmi.*` and `usb.*` actions wired through it.
7. Stream Deck plugin.

## 7. Rules for the implementing agent

- **Hardware writes are whitelisted.** Only the code and value pairs in section 3 may be written, on the transports named there. No scanning, no probing, no "let's try a value". Discovery stays in the prototype, run by Felipe.
- **Tests never touch hardware.** `swift test` runs against `FakeDDC` and `MockESP32` with the byte vectors from this brief. Hardware checks are a documented manual checklist behind a `--hardware` flag on the CLI.
- **Verify after every write** with a video-cable read and surface the result; never report success from the write alone.
- Swift 6 strict concurrency, deployment target macOS 15, no third-party dependencies in the core packages. SwiftLint if it is cheap.
- Conventional commits, one tracer bullet per PR, README kept current, MIT licence.
- When something in this brief turns out to be wrong on the hardware, stop and report it with the raw bytes; do not work around it silently.
