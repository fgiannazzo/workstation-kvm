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
parameter.

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
- `404` `{ "error": "unknown id", "id": "…" }`
- `409` `{ "error": "busy", "runId": "…" }` when another run is in progress.

### `GET /events`

`text/event-stream`. On connect the server sends one `state` event, then:

```
event: state
data: { …SwitchboardState… }

event: run
data: { "runId": "7f3c…", "id": "guest", "kind": "macro", "status": "started",
        "step": 0, "stepCount": 2, "message": "" }

event: run
data: { "runId": "7f3c…", "id": "guest", "kind": "macro", "status": "step",
        "step": 1, "stepCount": 2, "message": "monitor.pbp.on: verified 0xD7 = 0" }

event: run
data: { "runId": "7f3c…", "id": "guest", "kind": "macro", "status": "finished",
        "step": 2, "stepCount": 2, "message": "ok" }

: keepalive
```

`status` is `started`, `step`, `finished` or `failed`; `message` on `failed` is the error.
A comment line `: keepalive` goes out every 15 s. A `state` event follows every change of
`SwitchboardState` (polls, actions, controller events). Clients reconnect with backoff
starting at 1 s, capped at 30 s.

## URL scheme

`switchboard://run/{id}` and `switchboard://run/{id}?port=2` behave like `POST /run/{id}`
without a token. The Stream Deck "Open" action (open a URL) is the simplest phase-1 key.

## CLI equivalents

`switchboardctl state`, `switchboardctl actions`, `switchboardctl macros`,
`switchboardctl run <id> [key=value…]`, `switchboardctl events`, `switchboardctl token`.
The CLI talks to the API when the app is running and prints a clear message pointing at the
app when it is not.
