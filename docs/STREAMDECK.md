# Stream Deck keys without the plugin (phase 1)

Every action and every macro can sit on a Stream Deck key using only what ships in the Stream Deck
app. No plugin, no Node, nothing to install on the guest machines. This is phase 1 of the brief;
the plugin in [`docs/STREAMDECK-PLUGIN.md`](STREAMDECK-PLUGIN.md) is phase 2 and adds live state
tiles and key feedback.

There are two ways to press a key, both verified on Stream Deck 7.6.0 (2026-10-12):

| | **System → Website** with a `switchboard://` URL | **System → Open** with a generated `.command` file |
| --- | --- | --- |
| What the key does | Hands the URL to macOS, which hands it to the Switchboard app | Opens the file with Terminal, which runs `switchboardctl run <id>` |
| Token | None | Read from the login keychain by `switchboardctl` |
| Needs the app running | Yes (macOS launches it if it is installed) | No: `switchboardctl run` uses the app when it is up and works by itself when it is not |
| Feedback on the key | None | A Terminal window with the run's progress; it stays open when the run fails |
| Setup | Type a URL per key | `switchboardctl streamdeck export` once, then pick a file per key |

Pick the URL for the simplest key; pick the wrapper when you want to see why a run failed, or when
the app is not installed (for example on a spare Mac that only has `switchboardctl`).

## Option 1: a Website key with a `switchboard://run/{id}` URL

1. In the Stream Deck app, drag **System → Website** onto a key.
2. In its **URL** field enter the URL of the macro or action, and leave the option to send the request
   in the background off (that one makes an HTTP request instead of opening the URL):

   | Key | URL |
   | --- | --- |
   | Guest | `switchboard://run/guest` |
   | Solo | `switchboard://run/solo` |
   | PBP off | `switchboard://run/monitor.pbp.off` |
   | USB to port 2 | `switchboard://run/usb.select?port=2` |
   | HDMI input of the LG 4K | `switchboard://run/hdmi.select?display=lg4k&input=2` |

3. Press the key. macOS hands the URL to the Switchboard app (no browser opens) and it behaves like
   `POST /run/{id}` (`docs/API.md`, "URL scheme"): the same ids, with an action's parameters as query
   items. There is no token because the request does not go
   through the HTTP API: macOS hands the URL to the app. Any program running as you can open such a
   URL, just as it could run `switchboardctl`; the token protects the HTTP port from everything else
   (other users, web pages).

An id is a macro id or an action id (a macro wins when both exist; a macro ignores the query).
`switchboardctl macros` and `switchboardctl actions` list them. To try a URL without a key:

```bash
open "switchboard://run/solo"
```

The URL scheme belongs to the menu bar app (tracer bullet 4: `App/Info.plist` registers it), so
this option works once the app is installed. Use **Website**, not **Open**: the Open action accepts the
URL in its field, but Stream Deck 7.6.0 cannot execute it (every press shows the warning triangle and
`StreamDeck.log` says `KA_Execute ... Invalid key press: failed to execute`). Verified with
`switchboard://run/monitor.read`: the Website key ran it through the app on every press.

## Option 2: an Open key with a generated `.command` wrapper

```bash
switchboardctl streamdeck export
```

writes one executable file per macro and per action that needs no parameters into
`~/Library/Application Support/Switchboard/StreamDeck/` (or the directory you pass), plus a
`README.txt`:

```
guest.command   solo.command   monitor.pbp.on.command   monitor.pbp.off.command   monitor.read.command
```

Each file is two lines of shell:

```bash
#!/bin/bash
exec "/path/to/switchboardctl" run guest
```

1. In the Stream Deck app, drag **System → Open** onto a key.
2. Choose the `.command` file in its **App / File** field (or drag the file onto it from Finder).
3. Press the key. macOS opens the file with Terminal, which runs it. Verified with
   `monitor.read.command`: Terminal printed `started`, `step 1/1` and `finished monitor.read: ok`.

Things to know:

- **Terminal windows.** Terminal opens a window for each press. To have it close after a good run,
  set Terminal → Settings → Profiles → Shell → "When the shell exits" to "Close if the shell
  exited cleanly". A failed run exits non-zero, so its window stays open with the failure.
- **Actions with parameters** (`usb.select`, `hdmi.select`, `delay`, ...) get no wrapper because a
  file cannot carry a different parameter per key. Make a macro with the step you want (a macro
  is a list of steps, `docs/DESIGN.md`, "Actions") and use its wrapper, or use option 1's query
  items.
- **The keychain.** `switchboardctl run` asks the app to do the work, which needs the API token. The
  first time, macOS asks whether `switchboardctl` may use the keychain item
  `io.github.fgiannazzo.switchboard`: choose **Always Allow**. It asks again after the binary is
  rebuilt or replaced, because the allowance belongs to that exact program.
- **Export again** after you add or rename a macro, or move or reinstall `switchboardctl`, because the
  files hold its absolute path. Exporting is safe to repeat: it rewrites only what changed and
  never deletes anything, so delete the wrapper of a macro you removed yourself.
- **Exit codes** are what Terminal shows when a run fails: 0 finished, 1 failed, 3 a monitor write
  was not verified, 6 the controller is not configured or did not answer, 7 another run is in
  progress. The run's own lines say which step failed.

## Why the Website key does not call the HTTP API

A **Website** key with a `switchboard://` URL is fine (option 1). Pointing one at the HTTP API
(`http://127.0.0.1:48600/run/...`) does not work, on purpose. It can only request a URL: no
`Authorization` header. The API wants the token in that header and refuses it anywhere else (a token
in a query string would sit in the browser history, the Stream Deck logs and any proxy), so the key
would have to put the token in the URL, which the API rejects with `401`. It would also hand the URL to
a browser, which opens a tab for every press. Use the `switchboard://` URL or the plugin.

## The plugin

[`docs/STREAMDECK-PLUGIN.md`](STREAMDECK-PLUGIN.md) covers the official plugin: a **Run** key that
calls `POST /run/{id}` with the token, lights up while the desk already matches it and shows a
triangle when a run fails; a **USB toggle** that shows the active USB port and switches to the next;
and a **State** tile that shows PBP, an input, the USB port or the controller's reachability live from
`GET /events`. It needs the app (or `switchboardctl serve`) and the token from `switchboardctl token`.
The two phases coexist: Website and Open keys keep working next to plugin keys.

## Trying the API by hand

For debugging, the same calls the keys make (`docs/API.md` is the full contract). The token is a
bearer token in a header, never in the URL:

```bash
TOKEN=$(switchboardctl token)
curl -s http://127.0.0.1:48600/health                                     # no token needed
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:48600/state
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:48600/macros
curl -s -N -H "Authorization: Bearer $TOKEN" http://127.0.0.1:48600/events   # state and run events
```

`POST /run/...` runs the real thing (a macro such as `solo` writes to the monitor); do it on purpose:

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN" -d '{"port":2}' http://127.0.0.1:48600/run/usb.select
```

Without the app, `switchboardctl serve` serves the same API from the command line (Ctrl-C stops it),
which is how the plugin is tried before the app exists; pair it with `switchboardctl controller mock`
and `switchboardctl settings set controllerURL http://127.0.0.1:48700` to run `usb.select` safely.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| URL key shows the warning triangle | It is an **Open** key; Stream Deck cannot execute a URL there | Use **System → Website** for `switchboard://` URLs |
| URL key does nothing | The app is not installed or has never been launched, so macOS does not know `switchboard://` | Launch the app once; test with `open "switchboard://run/monitor.read"` |
| Terminal says `Switchboard app is not running` | `switchboardctl state` or `events` was used with no app: those need one (exit 8) | Start the app, or `switchboardctl serve` |
| Wrapper window shows `rejected the API token (401)` | The app runs with another token than the keychain's | `switchboardctl token` prints the one this tool uses; the app's settings pane shows the other |
| Wrapper window shows the keychain error text | The keychain was locked or the prompt was dismissed | Unlock the login keychain, press the key again, choose Always Allow |
| `failed ... usb.select: controller unreachable` | The ESP32 (or the mock) is not at `controllerURL` | `switchboardctl controller state`, `switchboardctl settings show` |
| Nothing opens, `No such file` | `switchboardctl` moved after the export | `switchboardctl streamdeck export` again |
