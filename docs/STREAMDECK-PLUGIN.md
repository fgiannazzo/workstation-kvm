# Stream Deck plugin

The official Switchboard plugin for the Elgato Stream Deck app lives in `StreamDeckPlugin/`, a
standalone npm package built with the Elgato SDK (`@elgato/streamdeck`). It is the phase 2
integration from the brief; the phase 1 keys (a **Website** key with a `switchboard://run/{id}` URL,
or an **Open** key with a generated `.command` file) keep working and are the fallback at the end of
this document.

Plugin UUID `io.github.fgiannazzo.switchboard`, category "Switchboard", three actions:

| Action | Kind | Does |
| --- | --- | --- |
| **Run** | key | `POST /run/{id}` on press. Lights up (green) while the desk already matches what it would do. Yellow triangle when the run is refused or fails. |
| **USB toggle** | key | Shows the active USB port large, on a colour per port. A press switches to the next port in its list. |
| **State** | informational tile | Shows one `SwitchboardState` field live from `GET /events`. Press to re-read `GET /state`. |

Everything the plugin does goes through the local API in [`docs/API.md`](API.md). It talks to the
configured host and port and nowhere else; the property inspector loads no remote script.

## Verified on a real Stream Deck

On 2026-10-12, Felipe at the keys and the agent reading logs:

- Stream Deck app **7.6.0** (build 23012) with its bundled Node.js **24.13.1**, a 15-key Stream Deck
  (5 × 3), macOS 27.0.1. The app launched the bundle with its own Node runtime; nothing else needed.
- The Switchboard menu bar app from `make app`, hosting the API on `127.0.0.1:48600`, with
  `controllerURL` pointed at `switchboardctl controller mock --port 48700`. No monitor writes: only
  `usb.select`, `hdmi.select`, `delay`, `notify` and `monitor.read` ran.
- Both install routes: `npx streamdeck link` with `restart`, and `npm run pack` installed by
  double-click (the Stream Deck log reports the install as `AllOk`).

What was seen, in the order of the sections below:

- The **Connection** section renders inside the inspector, global settings persist across plugin
  restarts and a reinstall from the packed file, and **Test connection** prints its green
  `token accepted` line.
- Run keys: the dropdown lists Macros and Actions from the app; `usb.select` with `{"port": 2}` reaches
  the controller (`POST /usb/select {"port":2} -> 200` at the mock); id `nope` gives the triangle and
  `HTTP 404: unknown id (id=nope)` in the log; a press while a 5 s `delay` runs gives the triangle and
  `HTTP 409: busy`; `notify` posts the notification.
- Lit keys and the USB toggle follow the port within a second, whether the change comes from a key,
  `switchboardctl run`, or the controller mock directly.
- State tiles update with no press: on this Mac the `state` event arrived 27 to 34 ms after a change made
  through the app or at the mock (334 ms once, for a change at the mock). Quitting the app turns every
  tile to `?`; after a relaunch they come back on the next reconnect attempt (1, 2, 4, 8 s backoff; 6.5 s
  after the relaunch in the test).

Bugs the device found, fixed in the same pull request: the Run inspector had two controls on one
setting and saved an empty id; a Run key opened the event stream only after the `202` and could miss a
fast run's result; and the check mark covered the key face, which already shows the new state.

## Prerequisites

- **Stream Deck app 7.1 or later** on macOS 15 or later. The plugin declares the Node.js 24 runtime
  that ships inside the Stream Deck app (`Nodejs.Version: "24"` in the manifest); 7.1 is the first
  version that provides it. Older apps will not list the plugin. Verified on 7.6.0.
- **The Switchboard app running** with its local API, and its token. Get the token from the app's
  Settings (Local API, Copy) or `switchboardctl token`.
- To build: **Node.js 24 or later** and npm (Node 26 / npm 12 is what the repository is built with).
  No Xcode, no Swift toolchain.

## Build

```bash
cd StreamDeckPlugin
npm ci            # exact versions from package-lock.json
npm run build     # tsc --noEmit, then rollup -> io.github.fgiannazzo.switchboard.sdPlugin/bin/plugin.js
npm test          # vitest, fully offline against a local mock of docs/API.md
npm run validate  # Elgato CLI manifest and layout validation
npm run pack      # dist/io.github.fgiannazzo.switchboard.streamDeckPlugin for installing by double-click
```

Dependency versions are pinned exactly (no `^`), so `npm ci` reproduces the same tree. `npm audit`
reports no known vulnerabilities at the time of writing.

## Install

Two ways; both leave the plugin running inside the Stream Deck app. They install the same UUID, so
use one at a time.

**Developer link** (what you want while iterating):

```bash
cd StreamDeckPlugin
npx streamdeck dev                                        # once: enables developer mode in the Stream Deck app
npx streamdeck link io.github.fgiannazzo.switchboard.sdPlugin
npx streamdeck restart io.github.fgiannazzo.switchboard  # after every build; `npm run watch` does it for you
```

`link` symlinks the `.sdPlugin` folder into
`~/Library/Application Support/com.elgato.StreamDeck/Plugins/`, so rebuilding updates the installed
plugin in place. A newly linked plugin appears after the `restart`; the Stream Deck app does not need
to be relaunched. `npx streamdeck unlink io.github.fgiannazzo.switchboard` removes the link.

**Packed file**: `npm run pack`, then double-click
`dist/io.github.fgiannazzo.switchboard.streamDeckPlugin` in Finder (unlink first if the developer link
is in place). The Stream Deck app copies the bundle into its Plugins folder and starts it. The package
holds the manifest, `bin/`, `ui/` and `imgs/`, never `logs/`. Keys and the connection settings survive
switching between the two routes. Uninstall from the app's preferences, Plugins tab.

## Connection settings (host, port, token)

Host, port and token are **global settings**: enter them once, every Switchboard key uses them.

1. Drag any Switchboard action onto a key.
2. In the property inspector, open the **Connection** disclosure at the bottom.
3. Host defaults to `127.0.0.1`, port to `48600`. Change the port only if you changed it in the app.
4. Paste the token. It is masked in the inspector, kept by the Stream Deck app with the plugin's
   global settings (not in Switchboard's keychain item), and never written to the plugin's logs.
5. Press **Test connection**. It calls `GET /health` (no token) and then `GET /state` (with the token)
   and prints one of:
   - `Switchboard 0.1.0: token accepted. PBP on, USB port 1, controller reachable` (green): all good.
   - `... answers at 127.0.0.1:48600, but no token is set`: paste the token.
   - `... rejected the token (401)`: the token is wrong or was regenerated; copy it again.
   - `No Switchboard at 127.0.0.1:48600: nothing is listening ...`: the app is not running or the port
     is wrong.

Changing any of the three fields reconnects the plugin at once (the log says `Using the Switchboard
API at 127.0.0.1:48600`). If you change the app's port in its Settings, change it here too: until then
the keys show `?` and the log repeats `nothing is listening at http://127.0.0.1:48600`.

## A Run key

1. Add **Switchboard → Run** to a key.
2. Pick the macro or action in the **Run** dropdown. The list comes from `GET /macros` and
   `GET /actions`, grouped as Macros and Actions; the refresh icon re-queries, for example after you
   add a macro in the app. A new key shows `Pick a macro or action`. The dropdown remembers the text of
   your choice, so a configured key still shows it while the app is down (the list itself then reads
   `Switchboard unreachable; start the app, then refresh`).
3. For actions with parameters, put a JSON object in **Parameters**; it is sent as the request body.
   Macros ignore it.

   | Action | Parameters |
   | --- | --- |
   | `usb.select` | `{"port": 2}` |
   | `hdmi.select`, `hdmi.resync` | `{"display": "dualup", "input": 1}` |
   | `delay` | `{"ms": 500}` |
   | `notify` | `{"text": "Guest mode"}` |

4. Give the key a title as usual (it sits at the bottom of the key); the plugin does not change it.

A press that works shows nothing extra: the key lighting up, or the USB toggle and the tiles changing,
is the feedback. The yellow alert triangle means it did not work: `400` (parameter missing or out of
range), `401` (token), `404` (unknown id), `409` (another run is in progress), a network failure,
invalid JSON in Parameters, no id picked, or an accepted run that ends `failed` (for example the
controller is unreachable). The reason is in the log.

Before it posts, the key joins the event stream and waits (at most 1 s) for its first `state` event,
after which the server is subscribed to run progress (`docs/API.md`, "Ordering"), so even a run that
fails within milliseconds is caught.

Run keys can go inside multi-actions (the manifest allows it; the lit state is skipped there). Not
tried on the device yet.

### Lit keys: which one is active

A Run key has two states, plain (dark) and lit (green). It is lit while the current state already is
what pressing it would make it, so a row of macro keys reads like radio buttons:

| The key runs | Lit while |
| --- | --- |
| a macro with `verify` | every `verify` field matches (Guest: `pbp` on and `usbPort` 2) |
| a macro without `verify` | the state matches what its steps set, later steps winning |
| `usb.select` `{"port": N}` | `usbPort` is N |
| `monitor.pbp.on` / `monitor.pbp.off` | `pbp` is `on` / `off` |
| `hdmi.select`, `hdmi.resync` `{"display": D, "input": N}` | `hdmiInput.D` is N |
| `delay`, `notify`, `monitor.read`, anything else | never |

Unknown values never match, so every key is dark while the plugin is not connected. Pressing does not
flip the state (`DisableAutomaticStates`); only the desk does. You can give each state its own icon in
the Stream Deck app. The plugin keeps a copy of the app's macros to know their `verify`; it reloads it
when the connection or a key changes, when the event stream reconnects, and when an inspector lists
the ids.

## The USB toggle

1. Add **Switchboard → USB toggle** to a key.
2. **Ports**: the ports a press cycles through, separated by commas (default `1,2`; `1,2,3` for three).
3. **Labels** (optional): names for the ports, `{"1": "Mac", "2": "Guest"}`.

The key draws its own face: `USB` on top, the active port (or its label) large in the middle, and
`next N` at the bottom, on one colour per port (1 blue, 2 orange, 3 purple, 4 teal; grey with `?` while
the port is unknown or the plugin is not connected). A press runs `usb.select` with the port after the
active one in the list, or the first one when the active port is unknown or not in the list. The key's
title is hidden by default because the face already says everything.

For one key per port instead, use Run keys with `usb.select` and `{"port": N}`: the active port's key
lights up.

## A State tile

1. Add **Switchboard → State** to a key.
2. Choose the **Field**: `pbp`, `mainInput`, `usbPort`, `controllerReachable`, or one of
   `hdmiInput.dualup`, `hdmiInput.lg4k`, `hdmiInput.samsung`.
3. Optionally map values to titles in **Labels**, a JSON object from value to text. Use `\n` for a
   line break. Examples:

   | Field | Labels |
   | --- | --- |
   | `pbp` | `{"on": "PBP ON", "off": "PBP OFF", "unknown": "?"}` |
   | `hdmiInput.lg4k` | `{"1": "Studio", "2": "Guest"}` |
   | `usbPort` | `{"1": "Mac", "2": "Guest"}` |
   | `controllerReachable` | `{"true": "ESP32 up", "false": "ESP32 down"}` |
   | any | add `"unknown": "n/a"` to replace the default `?` |

Values without a label are shown as they are (`hdmi1`, `2`, `true`). The tile shows `?` while the
value is unknown (`"unknown"`, `null`, or a missing `hdmiInput` key) and while the plugin is not
connected to the app's event stream. Pressing the tile re-reads `GET /state`; a failed read shows the
alert triangle.

Leave the key's own title empty: the plugin sets the title, and Stream Deck only lets it do so when
the user has not typed one.

### How the keys stay live

The plugin keeps **one** `GET /events` connection per Stream Deck process, however many Switchboard
keys are on screen, and holds it open while at least one is visible. If the stream drops it reconnects
with backoff from 1 s doubling to 30 s, as `API.md` requires; tiles show `?` and lit keys go dark
until the first `state` event after reconnecting. A stream that goes quiet for 45 s (three missed
`: keepalive` comments) is treated as dead and reconnected. Because of the backoff, keys can take up
to 30 s to recover after the app has been down for a minute or more.

## Logs

The SDK writes `logs/io.github.fgiannazzo.switchboard.N.log` inside the installed plugin folder, `0`
being the newest: `StreamDeckPlugin/io.github.fgiannazzo.switchboard.sdPlugin/logs/` when linked,
otherwise
`~/Library/Application Support/com.elgato.StreamDeck/Plugins/io.github.fgiannazzo.switchboard.sdPlugin/logs/`.
Every accepted run is an `INFO` line with its `runId` and result; every refused or failed run and every
stream disconnect is a `WARN` line with the HTTP status or the network error. The token is never
logged; raise `streamDeck.logger.setLevel` in `src/plugin.ts` to `debug` or `trace` only on a private
machine, because `trace` records every message exchanged with Stream Deck. The Stream Deck app's own log
is `~/Library/Logs/ElgatoStreamDeck/StreamDeck.log`.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Yellow triangle on every press, log says `HTTP 401: unauthorized` | Wrong or regenerated token | Copy it again from the app or `switchboardctl token`, paste under Connection, Test connection |
| Triangle, log says `nothing is listening at http://127.0.0.1:48600; is the Switchboard app running?` | App not running, or its API port differs | Launch the app; check the port in the app's Settings matches the Connection port |
| Every State tile shows `?`, every key dark | Not connected (same causes as above), or the value really is unknown, for example `usbPort` before the first controller read | Fix the connection; press a tile to force `GET /state`; check the app's own state view |
| Triangle, log says `Key pressed without an id` | Nothing picked in the Run dropdown | Pick a macro or action |
| Triangle, log says `HTTP 404: unknown id` | The macro was renamed or deleted in the app | Pick it again from the dropdown (refresh first). Macro ids win over action ids when both exist |
| Triangle, log says `HTTP 400: missing parameter (parameter=port)` | Action needs a body | Fill in Parameters, see the table above |
| Triangle, log says `HTTP 409: busy` | Another run is in progress | Wait for it; the keys update when it finishes |
| Triangle, log says `failed at step 1/1: ...` | The app accepted the run and it failed, for example the controller is unreachable | Read the message; `switchboardctl controller state` |
| Triangle, log says `parameters is not valid JSON` | Parameters field is not a JSON object | Use `{"port": 2}` style, double quotes |
| A macro key never lights up | The macro has no `verify` and none of its steps sets a state field, or the state differs in a field you did not expect | Add a `verify` to the macro; compare with `switchboardctl state` |
| Dropdown reads `Switchboard unreachable; start the app, then refresh` | App not reachable from the inspector | Start the app and press the refresh icon; configured keys keep their choice |
| Plugin missing from the actions list | Stream Deck app older than 7.1 (no Node 24 runtime), or the bundle failed validation | Update the app; run `npm run validate`; look for `Switchboard` under its own category |
| Plugin listed but keys do nothing, no log file appears | Build output missing (`bin/plugin.js`) | `npm run build`, then `npx streamdeck restart io.github.fgiannazzo.switchboard` |
| Stream Deck app reports the plugin crashed | See the newest `logs/*.log` | Open an issue with the log; the token is not in it |

### Fallback without the plugin

Two built-in Stream Deck actions work with no plugin and no token ([`docs/STREAMDECK.md`](STREAMDECK.md)):

- **System → Website** with a `switchboard://` URL, which macOS hands to the app:
  `switchboard://run/guest`, `switchboard://run/monitor.pbp.off`, `switchboard://run/usb.select?port=2`.
  Verified with `switchboard://run/monitor.read` on Stream Deck 7.6.0: no browser opens, the app runs it.
  **System → Open** does not take these URLs (the Stream Deck log says `failed to execute`).
- **System → Open** with a `.command` file from `switchboardctl streamdeck export`.

Both behave like `POST /run/{id}` but give no feedback on the key and nothing for tiles. Use them if the
plugin cannot be installed, for example on a Stream Deck app version without the Node runtime.

## Development notes

```
StreamDeckPlugin/
  package.json, package-lock.json       pinned versions; scripts: build, watch, test, typecheck, validate, pack, link, icons
  rollup.config.mjs, tsconfig*.json     same layout as the official `streamdeck create` template
  src/
    plugin.ts                           entry: registers the actions, connects, loads global settings
    api.ts                              ApiClient: health, state, actions, macros, run, events (SSE with backoff)
    sse.ts                              incremental text/event-stream parser
    events-hub.ts                       the single shared /events connection, fanned out to keys
    run-watch.ts                        follows one run on the stream, joined before the POST
    macro-catalog.ts                    the app's macros, for lit macro keys
    active.ts                           pure: is the desk already what a key would make it
    usb-toggle.ts                       pure: port list, next port, the USB toggle's SVG face
    connection.ts, settings.ts          global settings -> ApiClient (never logs the token)
    state-format.ts                     pure: field extraction and label mapping for State tiles
    parameters.ts                       pure: Parameters JSON -> request body
    pi-messages.ts                      property inspector requests: id list, Test connection
    actions/run.ts, usb.ts, state.ts    the three Stream Deck actions
  test/                                 vitest; mock-server.ts serves the shapes in docs/API.md
  scripts/make-icons.mjs                regenerates every PNG in imgs/ (`npm run icons`)
  io.github.fgiannazzo.switchboard.sdPlugin/
    manifest.json, imgs/, ui/           the bundle Stream Deck loads; bin/ is the build output
```

- `npm run watch` rebuilds on change and restarts the plugin in the Stream Deck app.
- The property inspectors use Elgato's `sdpi-components` web components, v4.0.1, vendored at
  `ui/sdpi-components.js` so nothing is fetched from the network at runtime. To upgrade, replace the
  file with the release from https://sdpi-components.dev/releases/v4/sdpi-components.js.
- `sdpi-components` does not keep two controls bound to the same setting in sync: give every setting
  exactly one control.
- The USB toggle draws its face as an SVG data URL (`setImage`, base64); Stream Deck 7.6 renders the
  SVG text, and it was readable at key size on the device.
- The tests never need the Stream Deck app or the Switchboard app. The Stream Deck side (key
  rendering, inspector behaviour, settings persistence) was checked by hand on the device; see
  "Verified on a real Stream Deck" above.
