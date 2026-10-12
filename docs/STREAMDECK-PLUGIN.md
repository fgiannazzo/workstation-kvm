# Stream Deck plugin

The official Switchboard plugin for the Elgato Stream Deck app lives in `StreamDeckPlugin/`, a
standalone npm package built with the Elgato SDK (`@elgato/streamdeck`). It is the phase 2
integration from the brief; the phase 1 route (a Stream Deck "Open" action with a
`switchboard://run/{id}` URL) keeps working and is the fallback at the end of this document.

Plugin UUID `io.github.fgiannazzo.switchboard`, category "Switchboard", two actions:

| Action | Kind | Does |
| --- | --- | --- |
| **Run** | key | `POST /run/{id}` on press. Green check on `202`, yellow triangle on anything else. |
| **State** | informational tile | Shows one `SwitchboardState` field live from `GET /events`. Press to re-read `GET /state`. |

Everything the plugin does goes through the local API in [`docs/API.md`](API.md). It talks to the
configured host and port and nowhere else; the property inspector loads no remote script.

## Prerequisites

- **Stream Deck app 7.1 or later** on macOS 15 or later. The plugin declares the Node.js 24 runtime
  that ships inside the Stream Deck app (`Nodejs.Version: "24"` in the manifest); 7.1 is the first
  version that provides it. Older apps will not list the plugin.
- **The Switchboard app running** with its local API enabled (tracer bullet 5), and its token.
  Get the token from the app's settings pane (copy button) or `switchboardctl token`.
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

Two ways; both leave the plugin running inside the Stream Deck app.

**Developer link** (what you want while iterating):

```bash
cd StreamDeckPlugin
npx streamdeck dev                                        # once: enables developer mode in the Stream Deck app
npx streamdeck link io.github.fgiannazzo.switchboard.sdPlugin
npx streamdeck restart io.github.fgiannazzo.switchboard  # after every build; `npm run watch` does it for you
```

`link` symlinks the `.sdPlugin` folder into
`~/Library/Application Support/com.elgato.StreamDeck/Plugins/`, so rebuilding updates the installed
plugin in place. `npx streamdeck unlink io.github.fgiannazzo.switchboard` removes it.

**Packed file**: run `npm run pack` and open `dist/io.github.fgiannazzo.switchboard.streamDeckPlugin`
(double-click in Finder). The Stream Deck app copies it into its Plugins folder. Uninstall from the
app's preferences, Plugins tab.

## Connection settings (host, port, token)

Host, port and token are **global settings**: enter them once, every Switchboard key uses them.

1. Drag any Switchboard action (Run or State) onto a key.
2. In the property inspector, open the **Connection** disclosure at the bottom.
3. Host defaults to `127.0.0.1`, port to `48600`. Change the port only if you changed it in the app.
4. Paste the token. It is masked in the inspector, stored by the Stream Deck app in the plugin's
   global settings (not in the keychain), and never written to the plugin's logs.
5. Press **Test connection**. It calls `GET /health` (no token) and then `GET /state` (with the token)
   and prints one of:
   - `Switchboard 0.1.0: token accepted. PBP on, USB port 2, controller reachable`: all good.
   - `... answers at 127.0.0.1:48600, but no token is set`: paste the token.
   - `... rejected the token (401)`: the token is wrong or was regenerated; copy it again.
   - `No Switchboard at 127.0.0.1:48600: nothing is listening ...`: the app is not running or the port
     is wrong.

Changing any of the three fields reconnects the plugin immediately.

## A Run key

1. Add **Switchboard → Run** to a key.
2. Pick the macro or action from the **From the app** dropdown. The list comes from `GET /macros` and
   `GET /actions`, grouped as Macros and Actions; the refresh icon re-queries. If the app is unreachable
   the dropdown says so and you can type the id into the **Id** field instead (`guest`,
   `monitor.pbp.on`, `usb.select`, ...). Both controls edit the same `id` setting.
3. For actions with parameters, put a JSON object in **Parameters**; it is sent as the request body.
   Macros ignore it.

   | Action | Parameters |
   | --- | --- |
   | `usb.select` | `{"port": 2}` |
   | `hdmi.select`, `hdmi.resync` | `{"display": "dualup", "input": 1}` |
   | `delay` | `{"ms": 500}` |
   | `notify` | `{"text": "Guest mode"}` |

4. Give the key a title and an icon as usual; the plugin does not change them.

On press the key shows the green check mark when the app answers `202 Accepted`, and the yellow
alert triangle for anything else: `400` (parameter missing), `401` (token), `404` (unknown id),
`409` (another run is in progress), a network failure, or invalid JSON in Parameters. The reason is
in the log. After a `202` the key also watches the event stream for that `runId` and shows the
triangle again if the run ends `failed`.

Run keys work inside multi-actions.

## A State tile

1. Add **Switchboard → State** to a key.
2. Choose the **Field**: `pbp`, `mainInput`, `usbPort`, `controllerReachable`, or one of
   `hdmiInput.dualup`, `hdmiInput.lg4k`, `hdmiInput.samsung`.
3. Optionally map values to titles in **Labels**, a JSON object from value to text. Use `\n` for a
   line break. Examples:

   | Field | Labels |
   | --- | --- |
   | `pbp` | `{"on": "PBP\nON", "off": "PBP\nOFF"}` |
   | `usbPort` | `{"1": "Mac", "2": "Guest"}` |
   | `controllerReachable` | `{"true": "ESP32 up", "false": "ESP32 down"}` |
   | any | add `"unknown": "n/a"` to replace the default `?` |

Values without a label are shown as they are (`hdmi1`, `2`, `true`). The tile shows `?` while the
value is unknown (`"unknown"`, `null`, or a missing `hdmiInput` key) and while the plugin is not
connected to the app's event stream. Pressing the tile re-reads `GET /state`; a failed read shows the
alert triangle.

Leave the key's own title empty: the plugin sets the title, and Stream Deck only lets it do so when
the user has not typed one.

### How the tiles stay live

The plugin keeps **one** `GET /events` connection per Stream Deck process, however many tiles are on
screen, and opens it only while at least one tile (or a Run key waiting on a run) needs it. If the
stream drops it reconnects with backoff from 1 s doubling to 30 s, as `API.md` requires, and tiles
show `?` until the first `state` event after reconnecting. A stream that goes quiet for 45 s (three
missed `: keepalive` comments) is treated as dead and reconnected.

## Logs

The SDK writes `logs/io.github.fgiannazzo.switchboard.N.log` inside the installed plugin folder:
`StreamDeckPlugin/io.github.fgiannazzo.switchboard.sdPlugin/logs/` when linked, otherwise
`~/Library/Application Support/com.elgato.StreamDeck/Plugins/io.github.fgiannazzo.switchboard.sdPlugin/logs/`.
Every refused run and every stream disconnect is a `WARN` line with the HTTP status or the network
error. The token is never logged; raise `streamDeck.logger.setLevel` in `src/plugin.ts` to `debug` or
`trace` only on a private machine, because `trace` records every message exchanged with Stream Deck.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Yellow triangle on every press, log says `HTTP 401: unauthorized` | Wrong or regenerated token | Copy it again from the app or `switchboardctl token`, paste under Connection, Test connection |
| Triangle, log says `nothing is listening at http://127.0.0.1:48600; is the Switchboard app running?` | App not running, or its API port differs | Launch the app; check the port in the app's settings matches the Connection port |
| Every State tile shows `?` | Not connected (same causes as above), or the value really is unknown, for example `usbPort` before the first controller read | Fix the connection; press a tile to force `GET /state`; check the app's own state view |
| Triangle, log says `HTTP 404: unknown id` | Typo in the id | Pick it from the dropdown. Macro ids win over action ids when both exist |
| Triangle, log says `HTTP 400: missing parameter (parameter=port)` | Action needs a body | Fill in Parameters, see the table above |
| Triangle, log says `HTTP 409: busy` | Another run is in progress | Wait for it; the state tiles update when it finishes |
| Triangle, log says `parameters is not valid JSON` | Parameters field is not a JSON object | Use `{"port": 2}` style, double quotes |
| Dropdown reads `Switchboard unreachable; type the id below` | App not reachable from the inspector | Type the id; the key still works once the app is up |
| Plugin missing from the actions list | Stream Deck app older than 7.1 (no Node 24 runtime), or the bundle failed validation | Update the app; run `npm run validate`; look for `Switchboard` under its own category |
| Plugin listed but keys do nothing, no log file appears | Build output missing (`bin/plugin.js`) | `npm run build`, then `npx streamdeck restart io.github.fgiannazzo.switchboard` |
| Stream Deck app reports the plugin crashed | See the newest `logs/*.log` | Open an issue with the log; the token is not in it |

### Fallback without the plugin: the URL scheme

The Stream Deck app's built-in **System → Open** action (open a URL) can fire any macro or action
with the app's URL scheme, no plugin and no token needed:

- `switchboard://run/guest`
- `switchboard://run/monitor.pbp.off`
- `switchboard://run/usb.select?port=2`

It behaves like `POST /run/{id}` but gives no feedback on the key (no check mark, no triangle) and
nothing for state tiles. Use it if the plugin cannot be installed, for example on a Stream Deck app
version without the Node runtime.

## Development notes

```
StreamDeckPlugin/
  package.json, package-lock.json       pinned versions; scripts: build, watch, test, typecheck, validate, pack, link, icons
  rollup.config.mjs, tsconfig*.json     same layout as the official `streamdeck create` template
  src/
    plugin.ts                           entry: registers the actions, connects, loads global settings
    api.ts                              ApiClient: health, state, actions, macros, run, events (SSE with backoff)
    sse.ts                              incremental text/event-stream parser
    events-hub.ts                       the single shared /events connection, fanned out to tiles
    connection.ts, settings.ts          global settings -> ApiClient (never logs the token)
    state-format.ts                     pure: field extraction and label mapping for State tiles
    parameters.ts                       pure: Parameters JSON -> request body
    pi-messages.ts                      property inspector requests: id list, Test connection
    actions/run.ts, actions/state.ts    the two Stream Deck actions
  test/                                 vitest; mock-server.ts serves the shapes in docs/API.md
  scripts/make-icons.mjs                regenerates every PNG in imgs/ (`npm run icons`)
  io.github.fgiannazzo.switchboard.sdPlugin/
    manifest.json, imgs/, ui/           the bundle Stream Deck loads; bin/ is the build output
```

- `npm run watch` rebuilds on change and restarts the plugin in the Stream Deck app.
- The property inspectors use Elgato's `sdpi-components` web components, v4.0.1, vendored at
  `ui/sdpi-components.js` so nothing is fetched from the network at runtime. To upgrade, replace the
  file with the release from https://sdpi-components.dev/releases/v4/sdpi-components.js.
- The tests never need the Stream Deck app or the Switchboard app. What they cannot cover is the
  Stream Deck side itself (key rendering, property inspector behaviour, global settings persistence),
  which needs a real Stream Deck app session.
