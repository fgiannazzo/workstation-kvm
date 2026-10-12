# Switchboard

A macOS menu bar utility for desk switching: drives the LG DualUp 28MQ780's picture-by-picture
mode over DDC/CI and the monitor's USB HID bridge, talks to an ESP32 controller for the HDMI and
USB switches, and exposes every action and macro to a Stream Deck.

## Status

Tracer bullets 1 to 7 of 7 (`docs/BRIEF.md`, section 6) are in. The hardware write path is
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
- `StateStore`: `Settings` and `SettingsStore` (`settings.json`), and the `@MainActor @Observable`
  `StateStore`: one `SwitchboardState`, a 500-entry log, and `changes`, a fan-out stream of states.
- `Actions`: the eight actions (`monitor.pbp.on|off`, `monitor.read`, `hdmi.select|resync`,
  `usb.select`, `delay`, `notify`) with validated parameters; the macro model and `MacroStore`
  (`macros.json`, with `guest` and `solo` created on first use); `MacroRunner`, which runs one
  macro or action at a time, stops at the first failing step (an unverified monitor write is a
  failure), checks the macro's `verify` against the state and publishes `run` events; `Runtime`
  and `StateRefresher`, the wiring the app and the API will start from.
- `switchboardctl run|actions|macros|settings`.
- `AppCore` and `SwitchboardApp`: the menu bar app (`make app`): a status glyph, a popover with the
  state and virtual controls, a macro editor, settings, a log, launch at login, and the
  `switchboard://run/{id}` URL scheme. See "Menu bar app" below.
- `LocalAPI`: the HTTP API of [`docs/API.md`](docs/API.md) on 127.0.0.1 (`LocalAPIServer`) with a bearer
  token in the login keychain, `GET /health|state|actions|macros|events`, `POST /run/{id}`, and
  server-sent events for state changes and run progress; `LocalAPIClient`, the Swift client
  `switchboardctl` uses; `StreamDeckWrappers`, the generated `.command` files for the Stream Deck
  "Open" action.
- `switchboardctl state|events|token|serve|streamdeck export`; `run`, `actions` and `macros` go
  through the app when it is running and work by themselves when it is not.

Next: the menu bar app starting the local API. `AppModel.startServices()` is the stub for it and
`LocalAPIServer.start(runtime:)` is the one line that fills it; until then `switchboardctl serve`
serves the same API. See `docs/BRIEF.md` for the specification and `docs/DESIGN.md` for the
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

Tests never touch hardware: they run against `FakeDDC` and a fake HID device with the brief's
byte vectors, and against `MockESP32` on loopback for everything network. `make` selects Xcode's
toolchain for you when Xcode is installed but `xcode-select` still points at the Command Line Tools.

`make app` builds the menu bar app into `dist/Switchboard.app` (see below); `make clean` removes it.

## Menu bar app

```bash
make app                   # release build, assembled and ad-hoc signed: dist/Switchboard.app
make run-app               # or: open dist/Switchboard.app
```

Switchboard shows up as a glyph in the menu bar: no Dock icon, no window at launch. The glyph is the
monitor's state: `rectangle.split.1x2` for PBP on, `rectangle` for PBP off, `questionmark.square.dashed`
for unknown. It is dimmed while the DualUp does not answer on the video cable (including the first
second after launch) and red while the last run's failure is still the last word (`lastError`).

Launching only reads: the app polls the monitor over the video cable every `pollingIntervalSeconds` and,
when a controller is configured, reads its state and listens to its events. It writes to the monitor
or the controller only when you press a control, run a macro or open a `switchboard://` URL.

Click the glyph for the popover:

- **State**: PBP, main input, USB port, and for each display the input the controller assumes it is
  on. The OREI switches cannot be read, so each assumption has an "Actually on..." menu: choose the
  input the display is really on and the controller is told (`hdmi.resync`), without pulsing the
  switch. Dots show whether the controller and the DualUp answer, then the last error and how long
  ago the state was updated.
- **Controls**: a button per macro, PBP on / PBP off / Read monitor (`monitor.pbp.on`,
  `monitor.pbp.off`, `monitor.read`), a segmented control for the USB port (1 to 4) and one per
  display for its HDMI input (1 or 2), and a text field with a Notify button. The USB and HDMI
  controls need a controller (set its address in Settings). They are disabled while a run is going.
- **Run row**: what is running (`Running guest, step 1 of 2`) with a progress bar, or how the last run
  ended; a failure shows the step and the reason, the same text `switchboardctl run` prints.
- **Macros...**, **Settings...**, **Log...** open their windows. **Quit** quits.

Windows:

- **Macros**: the macro editor. A list of macros (add, duplicate, remove, drag to reorder); for the
  selected one its id (the `{id}` of `switchboard://run/{id}`), name, ordered steps and an optional
  verify. Add a step by choosing an action; each step gets the controls its action's parameters
  call for (a picker for a choice, a number with a stepper for an integer, a text field for text),
  and moves up or down or is removed. Problems are listed in red as you type, with the same rules
  `macros.json` is validated by; Save writes `macros.json` only when the whole list is valid.
  `switchboardctl macros` sees the result at once.
- **Settings**: controller address (with a Discover button that browses `_switchboard._tcp` and fills
  the field in; macOS asks for Local Network access the first time), the display name substring that
  finds the DualUp, the polling interval, the local API port (the API itself and its token come with
  tracer bullet 5), launch at login, and the folder where `settings.json` and `macros.json` live, with a
  Reveal in Finder button. Save applies the settings: a new controller address, display name or polling
  interval rebuilds the app's wiring (the log and the last reading carry over).
- **Log**: the app's log, newest first, with a minimum-level filter and Copy all (plain text, oldest
  first). The same lines also go to the unified log under the subsystem `io.github.fgiannazzo.switchboard`
  (`log stream --predicate 'subsystem == "io.github.fgiannazzo.switchboard"'`).

Launch at login uses `SMAppService`, which only works from the app bundle: from `swift run` the Settings
toggle says to open `dist/Switchboard.app`. If macOS wants approval, the toggle stays on and says to approve
Switchboard in System Settings > General > Login Items. The toggle shows what macOS says, not what the
file says. The first time something posts a notification (the `notify` action, or a `switchboard://` run
that fails) macOS asks for permission; without it the text goes to the log.

The URL scheme runs a macro, or an action with parameters, like `POST /run/{id}` will without a token
(`docs/API.md`). From Terminal, or a Stream Deck "Open" key:

```bash
open "switchboard://run/solo"                 # a macro
open "switchboard://run/usb.select?port=2"    # an action with its parameters
```

A macro id wins over an action id, and a macro ignores the query. The app is started if it is not
running. A URL that does not parse, an unknown id, a bad parameter or a run that fails is shown as a
notification (a run that works is quiet; the state and the glyph show the result). Only one run goes at
a time. `solo` and `guest` need the controller like they do on the command line, and `guest` turns
PBP on over the USB bridge, which does not take effect yet (GitHub issue #5).

The app is signed ad hoc (`codesign -s -`) and never leaves your Mac: no App Store, no notarisation.
Environment: `SWITCHBOARD_SUPPORT_DIR` points the app at another settings and macros directory and
`SWITCHBOARD_CONTROLLER_URL` overrides the controller address, as for `switchboardctl`.

## Usage

```bash
swift run switchboardctl monitor list
swift run switchboardctl monitor read [--display SDQHD] [--json]
swift run switchboardctl monitor pbp on|off [--display SDQHD] [--json] [--dry-run]
swift run switchboardctl monitor bridge list
swift run switchboardctl monitor bridge reset
swift run switchboardctl run guest [--json]                # a macro: PBP on, USB to port 2, then verify
swift run switchboardctl run usb.select port=2             # a single action with its parameters
swift run switchboardctl run guest --local                 # in this process, never through the app
swift run switchboardctl actions [--json]
swift run switchboardctl macros [--json]
swift run switchboardctl settings show [--json]
swift run switchboardctl settings set controllerURL http://127.0.0.1:48700
swift run switchboardctl state [--json]                    # the app's state, through the local API
swift run switchboardctl events [--json]                   # state and run events, until Ctrl-C
swift run switchboardctl token                             # the local API's bearer token
swift run switchboardctl serve [--port N] [--poll]         # the local API without the app
swift run switchboardctl streamdeck export [DIR]           # .command wrappers for Stream Deck keys
swift run switchboardctl --version
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

`run <id> [key=value ...]` starts a macro or an action (a macro id wins when both exist; a macro
ignores the parameters) and prints each run event as it happens, as text or, with `--json`, one JSON
object per line (the shape of the `run` events in `docs/API.md`):

```
started guest (2 steps)
step 1/2: monitor.pbp.on: verified 0xD7 = 0
step 2/2: usb.select: port 2
finished guest: ok
```

A macro runs its steps in order and stops at the first one that fails; a monitor write the
video-cable read-back does not confirm is a failure (`failed guest at step 1/2: monitor.pbp.on:
unverified: 0xD7 read back 1 (off), expected 0 (on)`). After the last step the macro's `verify` is
compared with the state. A macro that needs the controller, or the monitor, fails before its first
step when there is none, so `guest` never turns PBP on and then finds it has no USB switch to move.
Exit codes of `run`: 0 finished, 1 failed, 3 a monitor write was not verified, 6 the controller is
not configured or not reachable, 7 another run is in progress.

The `hdmi.*` and `usb.*` actions (and so `guest` and `solo`) need a controller: set it once with
`settings set controllerURL http://host:port` or per shell with `SWITCHBOARD_CONTROLLER_URL`
(the environment wins). `settings.json` and `macros.json` live in
`~/Library/Application Support/Switchboard/`; `SWITCHBOARD_SUPPORT_DIR` points the CLI somewhere
else. `macros.json` is `{"macros": [...]}`, the same shape `GET /macros` serves; edit it by
hand to add macros (`docs/DESIGN.md`, "Actions", has the format). The settings are
`controllerURL`, `displayNameContains` (default `SDQHD`), `pollingIntervalSeconds` (30),
`localAPIPort` (48600) and `launchAtLogin` (false).

Exit codes: 0 ok, 1 error, 2 display not found, 3 write unverified, 4 USB bridge not found,
5 USB bridge busy (another client, typically a browser's WebUSB client, holds it exclusively),
6 controller unreachable (`controller` and `run` commands), 7 another run in progress (`run`),
8 the Switchboard app is not running (`state`, `events`).

Hardware checks are manual and live in `docs/HARDWARE-CHECKLIST.md`.

## Local API

The API listens on `http://127.0.0.1:48600` (the `localAPIPort` setting), loopback only. The menu bar
app is meant to start it at launch (`LocalAPIServer.start(runtime:)`, not wired in yet); until then
`switchboardctl serve` serves the same thing from the command line. [`docs/API.md`](docs/API.md) is
the contract; the Stream Deck plugin, `switchboardctl` and the generated wrappers are all written
against it.

| Request | Answers |
| --- | --- |
| `GET /health` (no token) | `{"ok":true,"name":"Switchboard","version":"0.1.0"}` |
| `GET /state` | the `SwitchboardState`: PBP, main input, USB port, HDMI inputs, reachability, last error |
| `GET /actions`, `GET /macros` | what can be run |
| `POST /run/{id}` | `202` with a run id; a macro or an action with a JSON body of parameters. `400` bad parameter, `404` unknown id, `409` another run in progress |
| `GET /events` | server-sent events: a `state` event on connect and on every change, `run` events for progress, `: keepalive` every 15 s |

Everything but `/health` needs `Authorization: Bearer <token>`. The token is 32 random bytes,
base64url, made on first launch and kept in the login keychain (service
`io.github.fgiannazzo.switchboard`, account `local-api-token`); `switchboardctl token` prints it.
It is never accepted in a URL.

```bash
TOKEN=$(swift run switchboardctl token)
curl -s http://127.0.0.1:48600/health
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:48600/state
swift run switchboardctl serve         # the same API without the app, for development
```

`run`, `actions` and `macros` use the app when `/health` answers within 300 ms (one run at a time,
shared with the menu bar) and do the work themselves when it does not. `state` and `events` need the
app and exit 8 without it. Setting `SWITCHBOARD_TOKEN_FILE=<path>` makes the CLI keep the token in a
file instead of the keychain (development and tests only).

## Stream Deck

Phase 1 needs no plugin: the built-in **System → Open** action opens `switchboard://run/{id}`, or a
`.command` wrapper written by `switchboardctl streamdeck export`. See
[`docs/STREAMDECK.md`](docs/STREAMDECK.md), which also says why the Website action does not fit.
Phase 2 is the plugin below.

## Hardware rules

The only writes in this codebase are the two `LGDualUpCommand` cases. Adding one needs a verified
fact in `docs/BRIEF.md` first. Never 0xF4 on source 0x50, never 0x60, no probing, no scanning.
Every write is verified by a video-cable read. See `CLAUDE.md` and `docs/DESIGN.md`.

## Licence

MIT, see `LICENSE`.

## Stream Deck plugin

`StreamDeckPlugin/` holds the official Stream Deck plugin (TypeScript, Elgato SDK): a Run key that fires any macro or action through the local API, and a State tile that shows live state from `/events`. Build, install and troubleshooting steps are in [`docs/STREAMDECK-PLUGIN.md`](docs/STREAMDECK-PLUGIN.md).
