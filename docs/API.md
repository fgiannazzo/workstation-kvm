# Switchboard local API

Contract for `LocalAPI` (served by the menu bar app) and for every client: `switchboardctl`,
the generated Stream Deck wrappers, and the Stream Deck plugin. Clients are written against
this file, not against the server source.

Base URL: `http://127.0.0.1:48600` (port is a setting). The server binds loopback only.

## Authentication

Every request except `GET /health` carries `Authorization: Bearer <token>`. The token is a
random 32-byte value, base64url without padding, generated on first launch and stored in the
keychain (service `io.github.fgiannazzo.switchboard`, account `local-api-token`).
`switchboardctl token` prints it; the app's settings pane shows it with a copy button.
Missing or wrong token: `401 {"error":"unauthorized"}`. Never accept the token as a query
parameter. The scheme name `Bearer` is case-insensitive. The token is checked before the request is
routed, so an unknown path or a wrong method without a token is `401` too (the API does not say
what exists); with a valid token they are `404 {"error":"not found"}` and
`405 {"error":"method not allowed"}` with an `Allow` header.

## Encoding

JSON, UTF-8. Dates are ISO 8601 with fractional seconds and `Z` (`2026-10-11T20:15:03.120Z`).
Enum values are lower-case strings. Unknown fields are ignored by clients.

## Resources

### `GET /health` (no auth)

```json
{ "ok": true, "name": "Switchboard", "version": "0.1.0" }
```

### `GET /state`

The `SwitchboardState` object:

```json
{
  "pbp": "on",                       // "on" | "off" | "unknown"
  "mainInput": "hdmi1",              // "hdmi1" | "hdmi2" | "unknown"
  "usbPort": 2,                      // 1..4 or null when unknown
  "hdmiInput": { "dualup": 1, "lg4k": 2, "samsung": 1 },   // assumed state, keys may be missing
  "controllerReachable": true,
  "dualUpReachable": true,
  "lastError": null,                 // string or null
  "updatedAt": "2026-10-11T20:15:03.120Z"
}
```

Every key is always present (`usbPort` and `lastError` are explicit `null`, `hdmiInput` is `{}`
when nothing is known). `updatedAt` of a state that has never been updated, such as a freshly
launched app before its first read, is `0001-01-01T00:00:00.000Z`.

### `GET /actions`

```json
{ "actions": [
  { "id": "monitor.pbp.on",  "title": "PBP on",  "parameters": [] },
  { "id": "monitor.pbp.off", "title": "PBP off", "parameters": [] },
  { "id": "monitor.read",    "title": "Read monitor", "parameters": [] },
  { "id": "hdmi.select", "title": "HDMI input", "parameters": [
      { "name": "display", "type": "enum", "values": ["dualup", "lg4k", "samsung"] },
      { "name": "input", "type": "int", "min": 1, "max": 2 } ] },
  { "id": "hdmi.resync", "title": "HDMI resync (set assumed input)", "parameters": [
      { "name": "display", "type": "enum", "values": ["dualup", "lg4k", "samsung"] },
      { "name": "input", "type": "int", "min": 1, "max": 2 } ] },
  { "id": "usb.select", "title": "USB to port", "parameters": [
      { "name": "port", "type": "int", "min": 1, "max": 4 } ] },
  { "id": "delay",  "title": "Wait", "parameters": [ { "name": "ms", "type": "int", "min": 0, "max": 60000 } ] },
  { "id": "notify", "title": "Notification", "parameters": [ { "name": "text", "type": "string" } ] }
] }
```

### `GET /macros`

```json
{ "macros": [
  { "id": "guest", "name": "Guest",
    "steps": [ { "action": "monitor.pbp.on" }, { "action": "usb.select", "port": 2 } ],
    "verify": { "pbp": "on", "usbPort": 2 } },
  { "id": "solo", "name": "Solo",
    "steps": [ { "action": "usb.select", "port": 1 }, { "action": "monitor.pbp.off" } ],
    "verify": { "pbp": "off", "usbPort": 1 } }
] }
```

A step is an object with `action` plus that action's parameters as sibling keys. `verify` is
optional; its keys are `SwitchboardState` field names and the values must match after the
last step.

### `POST /run/{id}`

`id` is a macro id or an action id. Body is optional JSON with the action's parameters
(ignored for macros). Macro ids win when an id is both.

- `202 Accepted` `{ "runId": "7f3c…", "id": "guest", "kind": "macro" }` (kind is `macro` or `action`). The run proceeds asynchronously; progress and result arrive on `/events`.
- `400` `{ "error": "missing parameter", "parameter": "port" }`
- `400` `{ "error": "invalid parameter", "parameter": "port", "reason": "must be 1 to 4, got 9" }`
- `400` `{ "error": "invalid body", "reason": "…" }` when the body is not a JSON object (an empty body, `null` and `{}` all mean "no parameters")
- `404` `{ "error": "unknown id", "id": "…" }`
- `409` `{ "error": "busy", "runId": "…" }` when another run is in progress.
- `500` `{ "error": "…" }` when `macros.json` cannot be read (the message names the file).

Every error body is `{ "error": "<code>" }` plus the keys listed for it. A run that is accepted and
then fails is not an HTTP error: the `202` has been sent, and the failure arrives as a `failed`
event.

### `GET /events`

`text/event-stream`. On connect the server sends one `state` event, then:

```
event: state
data: { …SwitchboardState… }

event: run
data: {"runId":"7f3c…","id":"guest","kind":"macro","status":"started","step":0,"stepCount":2,"message":""}

event: run
data: {"runId":"7f3c…","id":"guest","kind":"macro","status":"step","step":1,"stepCount":2,"message":"monitor.pbp.on: verified 0xD7 = 0"}

event: run
data: {"runId":"7f3c…","id":"guest","kind":"macro","status":"finished","step":2,"stepCount":2,"message":"ok"}

: keepalive
```

Every event's `data` is one complete JSON document on a single `data:` line. `status` is
`started`, `step`, `finished` or `failed`; `message` on `failed` is the error. `step` counts
completed steps: 0 on `started`, 1 after the first step, `stepCount` on `finished`. On `failed` it
is the 1-based number of the step that failed (a macro's `verify` counts as step `stepCount`), or 0
when the run failed before its first step, for example a macro that needs the controller when none
is configured. A single action runs as a one-step run (`stepCount` 1, `kind` `action`). A comment line
`: keepalive` goes out every 15 s; clients may treat 45 s of silence as a dead connection. A `state` event follows every change of
`SwitchboardState` (polls, actions, controller events). Clients reconnect with backoff
starting at 1 s, capped at 30 s.

Ordering: the server subscribes to run progress before it sends the connect-time `state`, so a
client that waits for that first event and then `POST`s a run cannot miss any of its `run` events.
The `state` and `run` events travel on separate streams, so no order between them is promised: the
`state` event that shows a run's result can arrive just before or just after its `finished`. Within
the `run` events of one run the order is always `started`, `step`…, then `finished` or `failed`.

## URL scheme

`switchboard://run/{id}` and `switchboard://run/{id}?port=2` behave like `POST /run/{id}`
without a token. A Stream Deck "Website" key with this URL is the simplest phase-1 key (the "Open"
action does not execute URLs; `docs/STREAMDECK.md`).

## CLI equivalents

`switchboardctl state`, `switchboardctl actions`, `switchboardctl macros`,
`switchboardctl run <id> [key=value…]`, `switchboardctl events`, `switchboardctl token`,
`switchboardctl serve` (this API, served by the CLI instead of the app, for development) and
`switchboardctl streamdeck export` (the `.command` wrappers).

`run`, `actions` and `macros` talk to the app when `GET /health` answers within 300 ms, so the app's
one runner and its busy rule apply, and do the work in process when it does not (`--local` always
does). `state` and `events` need the app: without it they print
`Switchboard app is not running (no API at http://127.0.0.1:PORT); start it, or use "switchboardctl run" which works offline`
and exit 8. The token comes from the keychain (the environment variable `SWITCHBOARD_TOKEN_FILE`
names a file instead, for development), the port from the `localAPIPort` setting or `--port N`.
