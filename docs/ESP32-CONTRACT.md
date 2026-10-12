# ESP32 controller contract

The HTTP contract between the Switchboard app and the ESP32 controller (the firmware is another
repository). It is the brief's section 5 (`docs/BRIEF.md`) made exact. The app side is
`ESP32Kit` (`ESP32Client`, `MockESP32`, `ContractTest`); the firmware side implements this file
and runs the contract test against itself.

Examples below are captured from `MockESP32` on the wire, so the bytes are real. JSON key order
is not significant; whitespace is not significant.

## Discovery

- mDNS service type **`_switchboard._tcp`**, advertised on the HTTP port (80 on the firmware).
- Instance name: any. The mock advertises `Switchboard Mock`; the firmware should use something
  that says which unit it is, for example `Switchboard Controller`.
- No TXT record is required or read.
- The app also accepts a configured address (`http://host:port`) and prefers it. mDNS is for
  first-time setup and `switchboardctl controller discover`.

## Transport

- HTTP/1.1, no TLS, JSON in UTF-8. Requests with a body send `Content-Type: application/json`;
  the controller may ignore that header.
- **No authentication.** Anyone on the LAN can switch the desk. This is a known gap, accepted for
  now (brief, section 5). Clients send no credentials; if auth is added later it is a contract
  change and this file changes first.
- Every request is answered within 3 s or the reference client gives up (`ControllerError.timeout`).
  A pulse sequence that can take longer must still answer inside that budget.
- Requests can arrive concurrently (the app, a Stream Deck and a CLI). Serialise the button
  pulses and RS-485 traffic inside the controller.

## The state object

Returned by every endpoint that succeeds (`GET /state`, all three `POST`s) and sent on every
event:

```json
{"hdmi":{"dualup":1,"lg4k":1,"samsung":1},"uptime":123,"usb":{"port":1,"source":"aten"}}
```

| Field | Type | Meaning |
|---|---|---|
| `hdmi.dualup`, `hdmi.lg4k`, `hdmi.samsung` | integer 1 or 2 | The **assumed** input of each OREI 2x1 switch. They are not readable, so this is what the controller last pulsed or was told with `resync`. All three keys are always present. |
| `usb.port` | integer 1 to 4 | The ATEN US3344I's active port, from its `usb p0x` / `info` reply. Authoritative. |
| `usb.source` | non-empty string | Where `usb.port` came from; `"aten"` today. |
| `uptime` | integer >= 0 | Seconds since the controller booted. |

Display ids are exactly `dualup`, `lg4k` and `samsung`. Clients ignore unknown keys, so new
fields can be added without breaking them.

## Endpoints

### `GET /state`

```
GET /state HTTP/1.1
```
```
HTTP/1.1 200 OK
Content-Type: application/json; charset=utf-8
Content-Length: 86

{"hdmi":{"dualup":1,"lg4k":1,"samsung":1},"uptime":1,"usb":{"port":1,"source":"aten"}}
```

### `POST /hdmi/{display}/select`

Moves the display's OREI switch to `input` by pulsing its select button until the assumed state
matches, then returns the new state. A short press toggles the input, so this is zero presses
when the assumed state already matches and one press otherwise.

```
POST /hdmi/lg4k/select HTTP/1.1
Content-Type: application/json

{"input": 2}
```
```
HTTP/1.1 200 OK
Content-Type: application/json; charset=utf-8

{"hdmi":{"dualup":1,"lg4k":2,"samsung":1},"uptime":5,"usb":{"port":1,"source":"aten"}}
```

`input` must be the integer 1 or 2 (not `"1"`, `true`, `1.5`). Anything else is
`400 {"error":"invalid input"}`.

### `POST /hdmi/{display}/resync`

Sets the assumed input **without pulsing**. This is the one-click correction when someone pressed
the physical button. Same request and reply shapes as `select`.

```
POST /hdmi/lg4k/resync HTTP/1.1
Content-Type: application/json

{"input": 1}
```
```
HTTP/1.1 200 OK
Content-Type: application/json; charset=utf-8

{"hdmi":{"dualup":1,"lg4k":1,"samsung":1},"uptime":5,"usb":{"port":1,"source":"aten"}}
```

### `POST /usb/select`

Sends `sw p0N` to the ATEN, reads back with `usb p0N`, and returns the state with `usb.port` taken
from the read-back (so a failed switch shows the port the ATEN is really on).

```
POST /usb/select HTTP/1.1
Content-Type: application/json

{"port": 2}
```
```
HTTP/1.1 200 OK
Content-Type: application/json; charset=utf-8

{"hdmi":{"dualup":1,"lg4k":1,"samsung":1},"uptime":6,"usb":{"port":2,"source":"aten"}}
```

`port` must be the integer 1 to 4, else `400 {"error":"invalid port"}`.

### `GET /events`

A server-sent event stream; see below.

## Errors

Every non-2xx reply is a JSON object with a human-readable `error` string. Clients show it and
use only the status code to decide what happened.

| Status | When | Body |
|---|---|---|
| 400 | `input` missing, not an integer, or not 1 or 2 | `{"error":"invalid input"}` |
| 400 | `port` missing, not an integer, or not 1 to 4 | `{"error":"invalid port"}` |
| 404 | `{display}` is not `dualup`, `lg4k` or `samsung` | `{"error":"unknown display"}` |
| 404 | any other path | `{"error":"not found"}` |
| 405 | wrong method for a known path; includes an `Allow` header | `{"error":"method not allowed"}` |
| 5xx | hardware trouble (RS-485 timeout, ATEN says `Command Incorrect`) | `{"error":"<what failed>"}` |

Order of checks: the display is validated first (404), then the body (400). A rejected request
never changes any state. The 5xx wording is the firmware's to choose; `502` for "the ATEN did not
answer correctly" is suggested. The contract test does not exercise 5xx.

```
POST /hdmi/projector/select  {"input": 1}   ->  404  {"error":"unknown display"}
POST /hdmi/dualup/select     {"input": 3}   ->  400  {"error":"invalid input"}
POST /usb/select             {"port": 5}    ->  400  {"error":"invalid port"}
```

## Events

`GET /events` answers `200` with `Content-Type: text/event-stream` and keeps the connection open.

```
GET /events HTTP/1.1
Accept: text/event-stream
```
```
HTTP/1.1 200 OK
Cache-Control: no-cache
Content-Type: text/event-stream
Connection: close

event: state
data: {"hdmi":{"dualup":1,"lg4k":1,"samsung":1},"uptime":6,"usb":{"port":2,"source":"aten"}}

: keepalive

```

- The **current state is sent immediately on connect**, then once per change of `hdmi` or `usb`.
  Uptime ticking is not a change.
- `data` is the full state object on **one line**. Never send a partial state.
- The event name is `state`. Clients ignore the name and accept any event whose data is a state,
  so a firmware library that sends unnamed events works too.
- A comment line `: keepalive` goes out every 15 s while idle. Clients treat 45 s of silence as a
  dead connection and reconnect.
- Clients reconnect with backoff starting at 1 s, doubling to 30 s, and the controller sends the
  current state again on every connection. There is no event id or replay.
- A controller serving several listeners (the app, a Stream Deck plugin, a CLI) should send each
  change to all of them.

## The mock

`MockESP32` implements all of the above in memory: `GET /state` with a ticking `uptime`; `select`
and `resync` validate and set the input (an optional `pulseDelay` simulates the button press
time); `usb/select` validates 1 to 4 and sets the port; `/events` sends the state on connect, on
every change and `: keepalive` every 15 s.

Run it for plugin or firmware development:

```bash
swift run switchboardctl controller mock                       # http://127.0.0.1:48700
swift run switchboardctl controller mock --port 48700 --host 0.0.0.0
swift run switchboardctl controller mock --advertise           # also binds 0.0.0.0 and publishes _switchboard._tcp
```

It prints its URL and one line per request (`12:03:11  POST /usb/select {"port":2} -> 200`) until
Ctrl-C. Point a client at it with `--url http://127.0.0.1:48700` or
`export SWITCHBOARD_CONTROLLER_URL=http://127.0.0.1:48700`. In Swift tests it is
`MockESP32(...)` plus `start()`; the hooks are `failNextRequest(status:)`, `setState(_:)`,
`requestLog`, `currentState` and `eventSubscriberCount`.

## The contract test

`ContractTest` is the executable form of this document. The app's unit tests run it against
`MockESP32`; the firmware repository runs it against the real board:

```bash
swift run switchboardctl controller contract-test --url http://<esp32>
# or
SWITCHBOARD_CONTROLLER_URL=http://<esp32> swift run switchboardctl controller contract-test
swift run switchboardctl controller contract-test --discover   # first _switchboard._tcp on the LAN
```

Output is one `PASS`/`FAIL` line per check and a summary; `--json` prints the checks as an array of
`{name, passed, detail}`. Exit codes: 0 every check passed, 1 a check failed (or other error),
5 the controller is unreachable.

| # | Check | What it does | Moves hardware? |
|---|---|---|---|
| 1 | `GET /state` returns the state object | Raw keys `hdmi`, `usb`, `uptime` present; all three display keys, each 1 or 2; `usb.port` 1 to 4; `usb.source` non-empty; `uptime` >= 0 | no |
| 2 | `POST /hdmi/dualup/resync` | Resync to the other input; the reply and a following `GET /state` show it and nothing else changed; resync back | no (assumed state only) |
| 3 | `POST /hdmi/lg4k/select` | Select the other input; reply and `GET /state` show it; select back | **yes**: two button pulses on the LG 4K's switch |
| 4 | `POST /usb/select` | Select another port (`port % 4 + 1`); reply and `GET /state` show it; select back | **yes**: the USB switch moves away and back |
| 5 | errors | Unknown display on `select` and `resync` is 404; input 0 and 3 are 400; USB port 0 and 5 are 400; the state is unchanged afterwards | no |
| 6 | `GET /events` | Content-Type is `text/event-stream`; a state event arrives within 3 s of connecting; a `resync` of `dualup` made during the subscription produces an event with the new value within 3 s; then it is resynced back | no (assumed state only) |

Each check reads what it needs, restores what it changed even when it fails, and reports a failed
restore as a failure. Checks 3 and 4 are why you should not run the test on the real desk while
a guest machine is using the USB switch.

The first request of a run is check 1's `GET /state`, which is how the unit tests prove that one
failing request fails exactly one check.

## Compatibility notes for the app

- The app talks plain HTTP to a LAN address, so the menu bar app (tracer bullet 4) will probably need
  `NSAppTransportSecurity > NSAllowsLocalNetworking` and, for mDNS under the Local Network
  privacy rules, `NSLocalNetworkUsageDescription` and `NSBonjourServices` containing
  `_switchboard._tcp`; confirm when that target exists. `switchboardctl` is a command line tool
  and needs none of it; macOS asks once for the terminal's Local Network access.
