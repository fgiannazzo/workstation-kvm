# Switchboard design notes

Decisions that every tracer bullet builds against. The brief (`docs/BRIEF.md`) is the
source of every protocol fact; this file only fixes names, layout and interfaces so that
work done in parallel fits together. When this file and the brief disagree, the brief wins
and this file gets fixed.

## Names

| Thing | Value |
|---|---|
| Product | Switchboard |
| Repository | `fgiannazzo/workstation-kvm` |
| Bundle identifier | `io.github.fgiannazzo.switchboard` |
| CLI | `switchboardctl` |
| Application Support | `~/Library/Application Support/Switchboard/` (`macros.json`, `settings.json`, `log.txt`) |
| Keychain item | service `io.github.fgiannazzo.switchboard`, account `local-api-token` |
| Token file (development) | env `SWITCHBOARD_TOKEN_FILE=<path>`: `switchboardctl` reads and writes the token there (mode 0600) instead of the keychain |
| Local API | `http://127.0.0.1:48600` (port configurable) |
| URL scheme | `switchboard://run/{id}` |
| mDNS service (ESP32) | `_switchboard._tcp` |
| os.Logger subsystem | `io.github.fgiannazzo.switchboard` |

## Toolchain

- Swift 6.4 with **Xcode 26 or later selected** (`xcode-select -p` prints the Xcode developer
  directory). Everything is SwiftPM: no `.xcodeproj`, no `xcodebuild`.
- Known toolchain bug, 2026-10-11: with only the Command Line Tools selected, SwiftPM's Swift
  Build backend passes `-load-resolved-plugin` for the Observation and Swift macros but not for
  `TestingMacros`, so some test targets fail with "plugin for module 'TestingMacros' not found".
  Until Apple fixes it, build with Xcode's toolchain: `sudo xcode-select -s
  /Applications/Xcode.app/Contents/Developer`, or per invocation
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. `make build` and
  `make test` set `DEVELOPER_DIR` automatically when Xcode is installed but not selected.
- `// swift-tools-version: 6.0`, `platforms: [.macOS(.v15)]`, Swift 6 language mode on every target.
- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`). Never import XCTest.
- The app bundle is assembled by `Scripts/make-app.sh` from the SwiftPM executable plus
  `App/Info.plist`, then ad-hoc signed (`codesign -s -`). `make app` wraps it.
- No third-party dependencies in the Swift package. The Stream Deck plugin (TypeScript, in
  `StreamDeckPlugin/`) is a separate npm package and may use the Elgato SDK.
- Verification for every PR: `swift build && swift test` (or `make build test`).

## Package layout

One `Package.swift` at the repository root.

```
Sources/
  IOAVServiceShim/      C. Declarations of the private IOAVService functions; links IOKit.
  USBReenumerate/       C. IOUSBLib re-enumeration of the LG bridge (from usbreset.c).
  SwitchboardCore/      Shared value types and protocols (no I/O). See below.
  DDCKit/               Packet encoders/decoders (pure), DDCTransport, VideoCableDDC,
                        LGUSBBridge, FakeDDC, display enumeration by EDID name.
  Devices/              LGDualUp: the whitelist and the verify-after-write flow.
  TinyHTTP/             Minimal HTTP/1.1 server on Network.framework, with SSE support.
                        Shared by MockESP32 and LocalAPI.
  ESP32Kit/             ESP32Client (URLSession + mDNS browse), MockESP32 (TinyHTTP).
  StateStore/           Settings, SettingsStore, and the @MainActor @Observable StateStore.
                        Depends on SwitchboardCore only (no devices).
  Actions/              Action registry, Macro model, MacroStore (JSON), MacroRunner, Runtime
                        (composition root) and StateRefresher (polling; the app starts it).
  AppCore/              Everything of the menu bar app that can be tested: AppModel, the
                        switchboard:// URL parser, status glyph, run progress, macro editor drafts.
                        No SwiftUI.
  LocalAPI/             HTTP API, keychain bearer token, SSE events, the Swift client, Stream Deck wrapper
                        generator.
  switchboardctl/       CLI executable.
  SwitchboardApp/       Menu bar app executable (SwiftUI MenuBarExtra): scenes and views only.
Tests/
  SwitchboardCoreTests/ DDCKitTests/ DevicesTests/ TinyHTTPTests/ ESP32KitTests/
  StateStoreTests/ ActionsTests/ AppCoreTests/ LocalAPITests/
App/Info.plist          LSUIElement, CFBundleURLTypes for switchboard://
Scripts/make-app.sh
StreamDeckPlugin/       Phase 2, npm package.
docs/                   BRIEF.md, DESIGN.md, HARDWARE-CHECKLIST.md, STREAMDECK.md, API.md
```

Dependency direction (arrows mean "depends on"; the app's own line, from tracer bullet 4, is
`SwitchboardApp -> AppCore -> Actions, StateStore, SwitchboardCore, ESP32Kit`):

```
switchboardctl, SwitchboardApp -> LocalAPI -> Actions -> Devices -> DDCKit -> IOAVServiceShim
                                   |            |                     \-> USBReenumerate
                                   |            +-> StateStore -> SwitchboardCore
                                   +-> TinyHTTP          ESP32Kit -> TinyHTTP, SwitchboardCore
Devices, DDCKit -> SwitchboardCore   (PBPState, MainInput)
Actions -> ESP32Kit, DDCKit, SwitchboardCore   (Runtime builds ESP32Client, VideoCableDDC, LGUSBBridge)
switchboardctl -> Actions, StateStore until LocalAPI exists (tracer bullet 3)
```

`SwitchboardCore` has no dependencies and no I/O. Nothing depends on an executable.

`switchboardctl` links `Devices` and `DDCKit` directly for `monitor list`, `monitor read`,
`monitor pbp on|off` and `monitor bridge list|reset`, and `Actions` and `StateStore` for `settings`
and for `run`, `actions` and `macros` when the app is not there (in-process, through `Runtime.live`;
the CLI does not start the `StateRefresher`). Since tracer bullet 5 `run`, `actions` and `macros`
prefer the local API: when `GET /health` answers within 300 ms they go through the app, so its one
runner and its busy rule apply, and otherwise (or with `--local`) they work in process as before.
`state` and `events` need the app (exit 8 without it). `settings` and `controller` stay local.
`serve` runs `LocalAPIServer` over `Runtime.live` in the CLI process, for development; `token`
prints the token; `streamdeck export` writes the `.command` wrappers. The code is in
`Sources/switchboardctl/API.swift`.

`switchboardctl` exit codes: 0 ok, 1 error, 2 display not found (`DDCError.displayNotFound`),
3 write unverified (`WriteOutcome.verified == false`), 4 USB bridge not found
(`DDCError.bridgeNotFound`), 5 USB bridge busy (`DDCError.bridgeBusy`), 6 controller not
configured or unreachable (`controller` commands, and `run` when `ActionError.isControllerUnreachable`),
7 another run in progress (`run`; `ActionError.busy`, or HTTP 409 from the app), 8 the Switchboard
app is not running (`state`, `events`: no API answered). `run` also exits 3 when a monitor write was
not verified and 1 for any other failed run. Through the app, 3 and 6 are recovered from the
`failed` event's message (`RunEvent.failureKind`), since the event carries text only. `--dry-run` on `monitor pbp` prints the bytes from
`Devices.DryRunFormatter` and constructs no transport.

## Concurrency

- Transports and clients are `actor`s. `StateStore` is `@MainActor @Observable final class`.
- No `@unchecked Sendable` without a comment saying why. No `DispatchQueue` where an actor
  does the job. IOKit callbacks hop back to the owning actor.
- Timing constants live in one `enum Timing` in `DDCKit` so tests can shorten them
  (`Timing.settleAfterModeChange = 4.0 s`, `Timing.betweenDumps = 0.5 s`,
  `Timing.readRetryGap = 0.15 s`, `Timing.requestToReply = 0.05 s`). Sleeps are injected as
  `public typealias Sleeper = @Sendable (Duration) async -> Void`: production passes
  `Timing.realSleep` (a wrapped `Task.sleep(for:)`), tests pass a closure that records the
  duration and returns at once, so the suite never waits.

## SwitchboardCore (shared types)

```swift
public enum DisplayID: String, Codable, CaseIterable, Sendable { case dualup, lg4k, samsung }

public enum PBPState: String, Codable, Sendable { case on, off, unknown }
public enum MainInput: String, Codable, Sendable { case hdmi1, hdmi2, unknown }

/// The ESP32 state object, exactly the JSON shape from the brief, section 5.
public struct ControllerState: Codable, Sendable, Equatable {
    public var hdmi: [DisplayID: Int]          // assumed input per display, 1 or 2
    public var usb: USB                        // { port: Int, source: String }
    public var uptime: Int
    public struct USB: Codable, Sendable, Equatable { public var port: Int; public var source: String }
}
// Note: `[DisplayID: Int]` must encode as a JSON object keyed by the raw string
// ("dualup", "lg4k", "samsung"), not as an array. Implement Codable by hand or use a
// CodingKeys-based struct; add a test that the exact JSON from the brief round-trips.

public protocol ControllerClient: Sendable {
    func state() async throws -> ControllerState
    func selectHDMI(_ display: DisplayID, input: Int) async throws -> ControllerState
    func resyncHDMI(_ display: DisplayID, input: Int) async throws -> ControllerState
    func selectUSB(port: Int) async throws -> ControllerState
    func events() -> AsyncStream<ControllerState>
}

/// The one observable model, published by StateStore and served by GET /state.
public struct SwitchboardState: Codable, Sendable, Equatable {
    public var pbp: PBPState = .unknown
    public var mainInput: MainInput = .unknown
    public var usbPort: Int? = nil
    public var hdmiInput: [DisplayID: Int] = [:]
    public var controllerReachable: Bool = false
    public var dualUpReachable: Bool = false
    public var lastError: String? = nil
    public var updatedAt: Date = .distantPast
}

public struct LogEntry: Codable, Sendable, Identifiable { id: UUID, date: Date, level: Level, message: String }
```

## DDCKit

Pure encoders, tested against these byte vectors (XOR checksum over `0x6E`, source, bytes):

| Packet | Bytes |
|---|---|
| VCP set 0xD7 = 1, source 0x51 | `84 03 D7 00 01 6E` |
| VCP set 0xD7 = 0, source 0x51 | `84 03 D7 00 00 6F` |
| VCP get 0xD7, source 0x51 | `82 01 D7 6B` |
| VCP get 0xF5, source 0x51 | `82 01 F5 49` |
| Capabilities fragment at offset 0, source 0x51 | `83 F3 00 00 4F` |
| VCP set 0xD7 = 1, source 0x50 (encoder only; never sent today) | `84 03 D7 00 01 6F` |
| USB bridge report, set 0xD7 = 0 | `08 01 55 03 07 00 03 37 51 84 03 D7 00 00 6F` then zero padding to 64 bytes |
| USB bridge follow-up for the same set | `08 02 55 04 0B 00 0B 37 51 84 03 D7 00 00 6F` then zero padding to 64 bytes |

Reply decoding (12 bytes read after a get): `bytes[2] == 0x02` else invalid; `bytes[3]` =
result code (0 = ok); `bytes[4]` = code; `bytes[6..7]` = max; `bytes[8..9]` = current.

```swift
public enum DDCSource: UInt8, Sendable { case standard = 0x51, lgSideChannel = 0x50 }
public struct VCPReply: Sendable, Equatable { resultCode: UInt8, code: UInt8, maximum: UInt16, current: UInt16 }

/// A raw write. The initialiser is `package`-scoped: only targets inside this package can
/// construct one, and by rule only `Devices.LGDualUp` does. Outside the package a write
/// that is not in the whitelist cannot be expressed.
public struct VCPWrite: Sendable, Equatable { public let code: UInt8; public let value: UInt16; public let source: DDCSource; package init(...) }

public protocol DDCTransport: Sendable {
    var name: String { get }
    func write(_ write: VCPWrite) async throws
    func read(code: UInt8) async throws -> VCPReply     // LGUSBBridge throws DDCError.readUnsupported
}

public actor VideoCableDDC: DDCTransport   // IOAVService; selected by EDID name, re-resolved on every call
public actor LGUSBBridge: DDCTransport     // IOHIDManager; write-only; paired to the display by EDID serial
public actor UnavailableTransport: DDCTransport   // placeholder; write throws bridgeNotFound(reason), read throws readUnsupported
public actor FakeDDC: DDCTransport         // records writes, serves scripted reads, for tests

public enum DDCError: Error {
    displayNotFound(String), ioKit(Int32, operation: String), invalidReply([UInt8]), readUnsupported, noReply, invalidEDID(String),
    bridgeNotFound(String),        // no LG bridge, or none pairs with the display; description appends DDCError.bridgeHint
    bridgeBusy(String),            // IOHIDDeviceOpen returned kIOReturnExclusiveAccess; detail names the likely holder
    unsupportedSource(DDCSource)   // LGUSBBridge refuses anything but source 0x51 before it reaches the wire
}
public static let DDCError.bridgeHint: String   // "is the DualUp's USB upstream on the Studio and selected in the OSD? Try `switchboardctl monitor bridge reset`."

/// Pure EDID parsing (unit-tested with a synthetic 128-byte EDID): name from descriptor 0xFC,
/// numeric serial from bytes 12-15 little-endian, serial string from descriptor 0xFF, PNP id, product code.
public struct EDID: Sendable { static func parse(_ data: Data) throws -> EDID }
public struct ExternalDisplay: Sendable { name: String, serial: UInt32, serialString: String?, manufacturer: String, productCode: UInt16, edid: Data }
public enum DisplayEnumerator { static func externalDisplays() throws -> [ExternalDisplay] }
```

Reads: a single `read` sends the request, waits `Timing.requestToReply`, reads 12 bytes, and
retries up to 3 times with `Timing.readRetryGap`. `DDCKit.StableReader.read(codes:)`
implements settle-and-double-dump: two passes `Timing.betweenDumps` apart, keep only
codes that agree, up to 4 attempts. An unreadable code is `nil`, never "changed".

### LGUSBBridge (tracer bullet 2, final)

```swift
public actor LGUSBBridge: DDCTransport {
    public static let vendorID = 0x043E, productID = 0x9A39, usagePage = 0xFF00
    public static let productString = "LG Monitor Controls"
    public static let reportID: UInt8 = 0x08           // buf[0] of the framing; hidapi sends it as the report id
    public static let minimumOutputReportSize = 63     // the interface that carries the 64-byte framing
    public static let exclusiveAccess: Int32           // kIOReturnExclusiveAccess, 0xE00002C5
    public nonisolated let name: String                // "USB bridge (SDQHD)"
    public init(displayNameContains: String = "SDQHD")                               // IOHIDManager + IOAVService
    package init(displayNameContains: String, provider: any HIDDeviceProvider, resolveDisplay: DisplayResolver)   // tests
    public static func listDevices() throws -> [BridgeDevice]
    public func device() throws -> BridgeDevice        // what a write would use, without opening it
    public func write(_ write: VCPWrite) async throws  // open, SetReport(output, 8, 64) x2, close; no run loop, no reply
    public func read(code: UInt8) async throws -> VCPReply   // always throws readUnsupported
}

public struct BridgeDevice: Sendable, Equatable, Hashable { vendorID, productID: Int; product, serial: String?; usagePage, maxOutputReportSize: Int }

public enum BridgePairing {   // pure, unit-tested
    static func matches(hidSerial: String?, display: ExternalDisplay) -> Bool
    static func choose(among devices: [BridgeDevice], display: ExternalDisplay?) throws -> Int
}

public enum USBReenumerator { static func reenumerateLGBridge() throws -> Int }   // wraps C usb_reenumerate_devices(0x043E, 0x9A39)

package protocol HIDReportSink: AnyObject { var device: BridgeDevice; func open() -> Int32; func setOutputReport(id: UInt8, _ bytes: [UInt8]) -> Int32; func close() -> Int32 }
package protocol HIDDeviceProvider { func matchingDevices() throws -> [any HIDReportSink] }
```

Send sequence, exactly the prototype's verified `uset` path: `IOHIDDeviceOpen(kIOHIDOptionsTypeNone)`,
`IOHIDDeviceSetReport(kIOHIDReportTypeOutput, 8, first, 64)`, the same for the follow-up report
from `DDCPacket.usbBridgeReports(set:value:)`, `IOHIDDeviceClose`. The bridge never answers;
the caller verifies over the video cable. Enumeration mirrors `lgusb.m`: `IOHIDManagerSetDeviceMatching`
on vendor and product, `IOHIDManagerOpen` (non-exclusive, the verified sequence), `IOHIDManagerCopyDevices`;
the manager is closed when the last device taken from it is released.

Pairing rule (`BridgePairing.matches`): the HID serial (`kIOHIDSerialNumberKey`) equals the EDID
serial string (descriptor 0xFF, case-insensitive, trimmed) or the numeric EDID serial rendered as
decimal or as hex (with or without `0x`). Selection (`BridgePairing.choose`): keep product 0x9A39
on usage page 0xFF00; with a resolved display keep only paired interfaces; without one (video
cable missing) accept the bridge only if every candidate carries the same serial and otherwise
throw `bridgeNotFound` saying there is more than one; prefer `maxOutputReportSize >= 63`.
`IOHIDDeviceOpen` returning `kIOReturnExclusiveAccess` maps to `bridgeBusy` naming a browser's
WebUSB client (Arc) and LG OnScreen Control as the likely holders. The IOKit calls sit behind
`HIDReportSink`/`HIDDeviceProvider` (`package` access) so the actor's device choice, pairing,
report sequence and error mapping are unit-tested with a fake; `IOHIDBridgeProvider` /
`IOHIDReportSink` are the thin adapters, one IOKit call per method, returning the raw `IOReturn`.

`USBReenumerate` (C target, from `usbreset.c`): `int usb_reenumerate_devices(uint16_t vendor_id,
uint16_t product_id_or_zero)` opens each matching `IOUSBHostDevice` through the IOUSBLib plug-in
and calls `USBDeviceReEnumerate`. Returns the count re-enumerated; -1 when service matching
failed, -2 when devices matched but none could be opened. The Swift wrapper throws
`DDCError.ioKit` for negative results and returns 0 when nothing matched.

## Devices.LGDualUp

```swift
public enum LGDualUpTransport: String, Sendable, Codable, CaseIterable { case usbBridge, videoCable }

public enum LGDualUpCommand: String, CaseIterable, Sendable, Codable {
    case pbpOn      // USB bridge only, 0xD7 = 0, expect read-back 0 on the video cable
    case pbpOff     // video cable only, 0xD7 = 1, expect read-back 1
    var code: UInt8 { 0xD7 }                 var value: UInt16 { 0 / 1 }
    var transport: LGDualUpTransport         var expectedReadBack: UInt16 { value }
    var targetState: PBPState { .on / .off }
    package var write: VCPWrite              // VCPWrite(code, value, .standard); the only VCPWrite construction in the package
}
public struct WriteOutcome: Sendable, Equatable, Codable {
    command: LGDualUpCommand, transport: String, expected: UInt16, observed: UInt16?, verified: Bool, reading: DualUpReading
}   // observed encodes as an explicit JSON null when unreadable
public enum DualUpCode { static let pbp: UInt8 = 0xD7; static let mainInput: UInt8 = 0xF5; static let stateCodes = [pbp, mainInput] }
public struct DualUpReading: Sendable, Equatable, Codable { pbp: PBPState, mainInput: MainInput, raw: [UInt8: UInt16] }
    // JSON: {"pbp": "off", "mainInput": "hdmi1", "raw": {"0xD7": 1, "0xF5": 1}}; pbp/mainInput re-derived from raw on decode
public enum DryRunFormatter { static func lines(for: LGDualUpCommand, displayNameContains: String) -> [String] }   // bytes only, no I/O
public actor LGDualUp {
    nonisolated let videoCable: any DDCTransport
    nonisolated let usbBridge: any DDCTransport
    init(videoCable: any DDCTransport, usbBridge: any DDCTransport, sleep: @escaping Sleeper = Timing.realSleep)
    init(videoCable: any DDCTransport, sleep: @escaping Sleeper = Timing.realSleep)   // usbBridge = UnavailableTransport: pbpOn throws bridgeNotFound
    func perform(_ command: LGDualUpCommand) async throws -> WriteOutcome   // write, settle, double-read 0xD7, compare
    func readState() async -> DualUpReading   // 0xD7 and 0xF5 via StableReader; never throws, unreadable = .unknown
}
```

`readState` does not throw: a code that cannot be read stably is `.unknown` and absent from
`raw`. Whether the display is connected at all is a separate question (`VideoCableDDC.display()`
throws `DDCError.displayNotFound`), which is how `switchboardctl` tells exit code 2 apart.

`perform`: pick the transport from the command, `write(command.write)` (a write error
propagates and nothing else happens), `await sleep(Timing.settleAfterModeChange)`, `StableReader`
read of `DualUpCode.stateCodes` over the video cable, `observed = raw[0xD7]`,
`verified = observed == expectedReadBack`. It never reports success from the write alone.
`observed == nil` means unknown, and `verified == false`; the caller surfaces that as
"unverified" (exit 3), not as failure of the monitor.

Deviations from the first draft of this file, recorded in tracer bullet 2: `WriteOutcome`
gained `reading` (the full post-write read, so callers refresh state without a second read);
`DualUpReading` and `WriteOutcome` are `Codable` with hand-written `raw` and `observed`
encodings; `LGDualUpTransport`, `targetState` and `DryRunFormatter` were added; `DDCError`
gained `unsupportedSource` alongside the planned `bridgeNotFound` and `bridgeBusy`, so the
bridge refuses a source 0x50 packet rather than encoding one; `switchboardctl` gained exit
code 5 (bridge busy) on top of the planned 3 and 4; `LGDualUp.videoCable`/`usbBridge` are
`nonisolated let`.

## ESP32Kit and TinyHTTP (tracer bullet 6)

The wire contract is `docs/ESP32-CONTRACT.md`; `ControllerState` and `ControllerClient` are in
`SwitchboardCore` as above. Final public signatures:

```swift
// TinyHTTP
public struct BonjourService: Sendable, Equatable { var name: String; var type: String }
public actor HTTPServer {
    init(host: String = "127.0.0.1", port: UInt16 = 0, bonjour: BonjourService? = nil, handler: @escaping Handler)
    // start() async throws, stop() async, port, isRunning, activeConnectionCount
}
// Router, HTTPRequest, HTTPResponse (.json/.text/.empty/.error/.eventStream), SSEEmitter,
// SSEParser and SSEParser.events(from:) as in the standalone TinyHTTP package.

// ESP32Kit
public enum ControllerError: Error, Sendable, Equatable {
    case unreachable(URL, underlying: String), httpStatus(Int, body: String), invalidResponse(String), timeout
}   // CustomStringConvertible + LocalizedError

public final class ESP32Client: ControllerClient, Sendable {
    public struct Backoff: Sendable, Equatable { var initial: Duration; var maximum: Duration; static let `default` }  // 1 s ... 30 s
    public let baseURL: URL
    public init(baseURL: URL, session: URLSession = .shared, timeout: Duration = .seconds(3), eventsBackoff: Backoff = .default)
    // state(), selectHDMI(_:input:), resyncHDMI(_:input:), selectUSB(port:), events() -> AsyncStream<ControllerState>
}

public struct DiscoveredController: Sendable, Equatable, Hashable { name: String; host: String; port: UInt16; url: URL }
public enum ESP32Discovery {
    static let serviceType = "_switchboard._tcp"
    static func browse(timeout: Duration) async -> [DiscoveredController]
    static func first(timeout: Duration) async -> DiscoveredController?
    static func resolve(_ endpoint: NWEndpoint, timeout: Duration = .seconds(3)) async -> (host: String, port: UInt16)?
    static func url(host: String, port: UInt16) -> URL?
}

public actor MockESP32 {
    public struct LoggedRequest: Sendable, Equatable { date: Date; method: String; path: String; body: String; status: Int }
    public init(host: String = "127.0.0.1", port: UInt16 = 0, initialState: ControllerState? = nil,
                pulseDelay: Duration = .zero, keepaliveInterval: Duration = .seconds(15),
                bonjour: Bool = false, bonjourName: String = "Switchboard Mock",
                now: @escaping @Sendable () -> Date = { Date() },
                onRequest: (@Sendable (LoggedRequest) -> Void)? = nil)
    // start() async throws, stop() async, port, url
    // test hooks: failNextRequest(status:), setState(_:), currentState, requestLog, eventSubscriberCount
}

public struct ContractCheck: Sendable, Equatable { name: String; passed: Bool; detail: String }
public struct ContractTest: Sendable { public init(baseURL: URL); public func run() async -> [ContractCheck] }
```

Behaviour worth knowing before building on it:

- `ESP32Client` gives every request one `timeout` deadline (`ControllerError.timeout`). `events()`
  ends only when the consumer stops iterating; a dropped or refused connection is retried with the
  backoff, which resets once a connection delivered a state. The event name is ignored: any event
  whose data decodes as `ControllerState` counts. Cancellation surfaces as `CancellationError`, never
  as a `ControllerError`.
- `ESP32Client` does not validate arguments (it will send `input: 3`); the controller's 400 comes
  back as `ControllerError.httpStatus(400, body:)`. Callers that want a friendlier message check
  first. `switchboardctl` does.
- `MockESP32.start()` after `stop()` comes back on the same port with the same state, which is what
  makes reconnect tests (and a "controller rebooted" demo) possible. A select or resync that does
  not change the value publishes no event; `setState` always does.
- The mock sends `event: state` on `/events`. Uptime is `now - start`, so tests that compare whole
  states inject `now:`.
- `ESP32Discovery` never throws and never hangs: it returns what it found when `timeout` passes,
  and an empty list if the browser cannot run (for example without the Local Network permission). It
  resolves over IPv4, since an ESP32 on a home LAN normally has no other address.
- `ContractTest` talks raw HTTP (it does not use `ESP32Client`), so it can send what the typed
  client cannot, such as an unknown display. On a real controller its `select` and `usb/select`
  checks move hardware; see `docs/ESP32-CONTRACT.md`.
- `switchboardctl controller ...` talks to the controller directly, also after tracer bullet 5:
  it diagnoses the board itself, which the app's local API does not expose. The commands live in
  `Sources/switchboardctl/Controller.swift`; `main.swift` only dispatches to them.
- The `hdmi.*` and `usb.*` actions sit on top of `ControllerClient`; tracer bullet 3 wired them
  (see Actions). `Runtime.live` builds an `ESP32Client` from `controllerURL` or
  `SWITCHBOARD_CONTROLLER_URL`.

## Actions

Action ids (strings, stable, used by the API and the Stream Deck):
`monitor.pbp.on`, `monitor.pbp.off`, `monitor.read`, `hdmi.select`, `hdmi.resync`,
`usb.select`, `delay`, `notify`, `displays.off`, `displays.on`.

Macro JSON (`macros.json` is `{"macros": [Macro]}`):

```json
{ "id": "guest", "name": "Guest", "steps": [
    { "action": "monitor.pbp.on" },
    { "action": "usb.select", "port": 2 },
    { "action": "hdmi.select", "display": "lg4k", "input": 2 },
    { "action": "delay", "ms": 500 },
    { "action": "notify", "text": "Guest mode" } ],
  "verify": { "pbp": "on", "usbPort": 2 } }
```

Steps run in order and the macro aborts on the first failure; an unverified monitor write
counts as a failure. `verify` is optional and compares fields of `SwitchboardState` after
the last step. Default macros shipped on first launch: `guest` (pbp on, usb port 2) and
`solo` (usb port 1, pbp off).

`ActionRegistry` resolves an id plus parameters to what the action does and runs it against an
`ActionContext` (final signatures below). With no controller configured, `hdmi.*` and `usb.*`
throw `ActionError.controllerUnavailable` with a message that names the setting and the
environment variable to fix. `POST /run/{id}` and `switchboardctl run {id}` accept a macro id
(parameters ignored) or an action id with its parameters.

### Displays off and on (`displays.off`, `displays.on`)

Not a monitor write: these change macOS's display configuration through BetterDisplay
(`docs/BRIEF.md`, "Physical displays off for remote sessions"). Signatures:

```swift
// SwitchboardCore
public enum DisplaysState: String, Codable, Sendable { case on, off, mixed, unknown
    static func aggregate(_ connected: [Bool]) -> DisplaysState }
public struct ManagedDisplay: Codable, Sendable, Hashable { name, uuid, serial?; func matches(_ selector: String) -> Bool }
public protocol DisplayConnector: Sendable {
    func displays() async throws -> [ManagedDisplay]                 // hardware framebuffers only (IOMobileFramebuffer), never virtual displays
    func isConnected(_ display: ManagedDisplay) async throws -> Bool?  // nil: unknown to the connector
    func setConnected(_ display: ManagedDisplay, _ connected: Bool) async throws
    func connectAll() async throws
}
// SwitchboardState.displays: DisplaysState (JSON "displays", default unknown)

// Devices
public struct BetterDisplay: DisplayConnector { static func installed(at:) -> BetterDisplay?
    init(executable:timeout:run:); static func parseIdentifiers(_:) -> [ManagedDisplay]? }
public typealias CommandRunner = @Sendable (URL, [String], Duration) async throws -> CommandOutput
public enum ProcessRunner { static let run: CommandRunner }        // no shell; kills after the timeout
public actor FakeDisplayConnector: DisplayConnector                 // tests

// Actions
public actor DisplaySwitch {
    init(connector:selectors:sleep:settle:attempts:)               // selectors = Settings.displaysToTurnOff
    func read() async -> DisplaysState
    func turnOff() async throws -> [String]                         // names; ActionError.verifyFailed per display
    func turnOn() async throws -> [String]                          // connectAll when no selectors
}
// ActionContext.displays, Runtime.displays: DisplaySwitch? (nil without BetterDisplay)
// ActionError.displaysUnavailable(String), .displaysNotConfigured
// Settings.displaysToTurnOff: [String] (names, serials or UUIDs; [] = every physical display)
```

Each switch is read back like a monitor write: `DisplaySwitch` reads every display up to `attempts`
times, `settle` apart, and fails with one line per display that never showed the wanted state. A
display it disconnected is remembered for the life of the process, so it still counts as off (and
is reconnected) if BetterDisplay stops listing it. `StateRefresher` reads `displays` on every poll and
logs a change. Tests use `FakeDisplayConnector` and an injected `CommandRunner`; nothing in
`swift test` starts BetterDisplay.

### Application layer (tracer bullet 3, final)

```swift
// SwitchboardCore (pure)
public enum JSONValue: Sendable, Equatable, Hashable, Codable {
    case string(String), int(Int), double(Double), bool(Bool), null, array([JSONValue]), object([String: JSONValue])
}   // ExpressibleBy{String,Integer,Float,Boolean,Nil,Array,Dictionary}Literal; stringValue, intValue
    // (also an integral double), doubleValue, boolValue, arrayValue, objectValue, isNull, subscripts

// StateStore
public struct Settings: Codable, Sendable, Equatable {
    var controllerURL: URL? = nil;  var displayNameContains = "SDQHD";  var pollingIntervalSeconds: Double = 30
    var localAPIPort = 48600;  var launchAtLogin = false
    func effectiveControllerURL(environment: [String: String]) -> URL?   // SWITCHBOARD_CONTROLLER_URL wins
    static func parseControllerURL(_ raw: String) -> URL?                // http(s)://host:port, or host:port
    mutating func set(_ key: String, to value: String) throws            // SettingsError; keys in Settings.Key
}
public enum AppSupport { static func defaultDirectory() -> URL; static func directory(environment:) -> URL }
    // ~/Library/Application Support/Switchboard/; SWITCHBOARD_SUPPORT_DIR overrides it (CLI, tests)
public actor SettingsStore {
    init(directory: URL = AppSupport.defaultDirectory())
    nonisolated var fileURL: URL, fileExists: Bool
    func load() throws -> Settings                  // missing file: defaults, nothing written
    func save(_ settings: Settings) throws          // creates the directory, atomic
    func update(_ change: @Sendable (inout Settings) throws -> Void) throws -> Settings
}
@MainActor @Observable public final class StateStore {
    static let logCapacity = 500
    private(set) var state: SwitchboardState;  private(set) var log: [LogEntry]
    init(initial: SwitchboardState = SwitchboardState(), now: @escaping @Sendable () -> Date = { Date() })
    func applyMonitor(pbp: PBPState, mainInput: MainInput, reachable: Bool)
    func apply(_ controller: ControllerState)       // hdmiInput, usbPort, controllerReachable = true
    func setControllerReachable(_:), setDualUpReachable(_:), setLastError(_: String?)
    func log(_ level: LogEntry.Level, _ message: String)    // ring buffer; does not touch state
    var changes: AsyncStream<SwitchboardState>      // current state first, then every mutation; one stream per access
}   // every state mutation sets updatedAt from `now` and publishes; the log does neither

// Actions
public enum ActionID: String, Codable, CaseIterable, Sendable { monitorPBPOn = "monitor.pbp.on", ... notify }
public struct ParameterDescriptor: Codable { name; type: .string | .int | .choice ("enum"); values: [String]?; min: Int?; max: Int? }
public struct ActionDescriptor: Codable { id: ActionID; title: String; parameters: [ParameterDescriptor] }
public struct ActionList: Codable { actions: [ActionDescriptor] }          // GET /actions
public struct MacroStep: Codable { action: ActionID; parameters: [String: JSONValue] }   // parameters are sibling keys
public struct MacroVerify: Codable { pbp: PBPState?; mainInput: MainInput?; usbPort: Int?; hdmiInput: [DisplayID: Int]? }
public struct Macro: Codable { id: String; name: String; steps: [MacroStep]; verify: MacroVerify? }
public struct MacroFile: Codable { macros: [Macro] }                      // macros.json and GET /macros
public actor MacroStore {
    init(directory: URL = AppSupport.defaultDirectory(), registry: ActionRegistry = ActionRegistry())
    static let defaultMacros: [Macro]               // guest, solo
    func load() throws -> [Macro]                   // reads macros.json; no file: writes the defaults first
    func macros() throws -> [Macro];  func macro(id: String) throws -> Macro?
    func save(_ macros: [Macro]) throws;  func upsert(_ macro: Macro) throws;  func remove(id: String) throws -> Bool
}   // save validates first (MacroValidator); a file on disk that is invalid is an error and is never overwritten
public struct ActionContext: Sendable {
    var dualUp: LGDualUp?;  var controller: (any ControllerClient)?;  var store: StateStore
    var notify: @Sendable (String) async -> Void;  var sleep: Sleeper
}
public enum ActionError: Error, Sendable, Equatable {
    case unknownID(String), missingParameter(String), invalidParameter(String, String)
    case controllerUnavailable(String), monitorUnavailable(String), unverified(WriteOutcome)
    case busy(runID: String), verifyFailed([String]), controller(ControllerError), cancelled
    var isUnverifiedWrite: Bool, isControllerUnreachable: Bool, isBusy: Bool       // for exit codes
}
public struct ActionRegistry: Sendable {
    let descriptors: [ActionDescriptor]             // docs/API.md order
    func validate(_ id: ActionID, parameters: [String: JSONValue]) throws -> ActionArguments
    func run(_ id: ActionID, parameters: [String: JSONValue], context: ActionContext) async throws -> String
}
public struct RunHandle: Codable, Sendable, Equatable { runId: String; id: String; kind: .macro | .action }   // the 202 body
public struct RunEvent: Codable, Sendable, Equatable {   // the `run` event
    runId, id, kind, status: .started | .step | .finished | .failed, step: Int, stepCount: Int, message: String
}
public actor MacroRunner {
    init(registry: ActionRegistry, macros: MacroStore, context: ActionContext)
    func start(id: String, parameters: [String: JSONValue] = [:]) async throws -> RunHandle
    var events: AsyncStream<RunEvent>               // one stream per access; subscribe before start
    func wait(_ handle: RunHandle) async -> RunEvent
    func error(of handle: RunHandle) -> ActionError?
    func execute(id: String, parameters: [String: JSONValue], onEvent: @Sendable (RunEvent) -> Void) async throws -> RunReport
    var currentRun: RunHandle?, activity: RunActivity
}
public struct Runtime: Sendable {                   // composition root
    let settings, controllerURL, dualUp, controller, store, macros, registry, context, runner, refresher
    @MainActor static func live(settings: Settings, environment: [String: String] = ProcessInfo.processInfo.environment,
                                appSupport: URL, notify: @escaping @Sendable (String) async -> Void = { _ in },
                                store: StateStore = StateStore()) -> Runtime   // `store:` added in tracer bullet 4
    @MainActor init(settings:controllerURL:dualUp:controller:appSupport:notify:sleep:store:)   // fakes in tests
}
@MainActor public final class StateRefresher {
    init(dualUp:controller:store:interval:sleep:activity:)
    func start(); func stop(); func refresh() async; var isRunning: Bool
}
```

How a run behaves, which `LocalAPI` (tracer bullet 5) serves as it is:

- `start` answers with the handle as soon as the run is accepted, after publishing `started`;
  the steps run in a task of their own. One run at a time: a second `start` throws
  `ActionError.busy(runID:)` with the running run's id (HTTP 409). The slot is released in the same
  turn as the `finished`/`failed` event, so a client that sees the event can start the next run.
- `start` throws, and runs nothing, for an unknown id (`unknownID`, 404) and for an action whose
  parameters are missing or invalid (`missingParameter`/`invalidParameter`, 400). A macro id wins
  over an action id; a macro ignores the parameters passed. It also throws a `MacroStoreError`
  when `macros.json` cannot be loaded and the id is not an action id. A macro's own steps were
  validated when `macros.json` was loaded or saved.
- A run that needs a device this process does not have (a controller step with no controller, a
  monitor step with no monitor) is accepted and fails before its first step: `started`, then
  `failed` with `step` 0 and the message of `ActionError.controllerUnavailable` (it names
  `controllerURL` and `SWITCHBOARD_CONTROLLER_URL`). `guest` therefore never switches PBP on and
  only then finds that `usb.select` has no controller.
- Events: `started` (step 0), `step` after each completed step (`step` = steps done, `message` =
  what the action reported, for example `monitor.pbp.on: verified 0xD7 = 0`), then `finished`
  (`step == stepCount`, `message` `ok`) or `failed`. On `failed`, `step` is the 1-based number of
  the step that failed (the macro's `verify` counts as step `stepCount`; 0 means no step ran) and
  `message` is `<action id>: <error>`, or `verify failed: usbPort: expected 2, got 1; ...`.
  A single action runs as a one-step run of kind `action`.
- A macro stops at the first failing step; later steps do not run. A monitor write that the
  video-cable read-back does not confirm is a failure (`ActionError.unverified`), and what was read
  still goes into the store. The `hdmi.*` and `usb.*` actions also fail (`verifyFailed`) when the
  state the controller answers with does not show the requested input or port.
- After the last step `verify` is compared with `store.state`; `unknown` never satisfies a field.
  A macro's `verify` keys are `pbp`, `mainInput`, `usbPort`, `hdmiInput` (an object with a subset of
  displays); an unknown key is an error when the file is loaded.
- The store: `monitor.*` actions write the post-write/post-read reading with `applyMonitor`;
  `hdmi.*`/`usb.*` write the controller's reply with `apply`. A run sets `lastError` when it fails
  (`<macro id>: <message>` for a macro, the message for an action) and clears it when a run
  finishes. Every run, step and failure is appended to `log`.
- `StateRefresher` (started by the app, never by the CLI) polls `readState()` every
  `pollingIntervalSeconds` and `controller.state()` with it, and applies `controller.events()`.
  A poll that overlaps a run (`RunActivity`) is thrown away, so a stale reading cannot overwrite
  what a run verified. It only reads.
- `Runtime.live` builds `VideoCableDDC` and `LGUSBBridge` for `displayNameContains`, an `ESP32Client`
  when `settings.effectiveControllerURL(environment:)` is non-nil, and the rest. Constructing it
  touches no hardware.

Deviations from the first draft of this section, recorded in tracer bullet 3: `ActionContext.notify`
is `@Sendable (String) async -> Void` (not a synchronous closure) and the context gained `sleep`;
`ActionError` gained `cancelled`; a run whose steps need a missing device fails before its first
step instead of at the step; `usb.select`, `hdmi.select` and `hdmi.resync` verify the controller's
reply; macro ids are restricted to letters, digits, `.`, `_` and `-` (they appear in URL paths);
`switchboardctl` gained `SWITCHBOARD_SUPPORT_DIR` and exit code 7.

## Menu bar app (tracer bullet 4, final)

`SwitchboardApp` (executable) is SwiftUI and nothing else: scenes, views, the status-item image and
an `NSApplicationDelegate` that receives `switchboard://` URLs. Every decision that is not drawing
lives in `AppCore` and is tested (`Tests/AppCoreTests`, over `FakeDDC`, a fake controller, a fake
notifier and a fake login item). `Scripts/make-app.sh` (`make app`) assembles `dist/Switchboard.app`
from `.build/release/SwitchboardApp` and `App/Info.plist` and signs it ad hoc.

```swift
// AppCore
public enum SwitchboardURL {                       // switchboard://run/{id}[?key=value&...]
    static func parse(_ url: URL) throws -> (id: String, parameters: [String: JSONValue])
}   // SwitchboardURLError: wrongScheme, unsupportedHost, missingID, unexpectedPath, invalidID, badParameter
    // Structural only. An action id's query goes through ActionDescriptor.parameters(fromText:); whether the
    // values are acceptable is the runner's call (a macro with that id would ignore them). A macro id's query
    // stays text. A parameter without a name or a value, or given twice, is badParameter.

public enum Tint { case primary, secondary, red }
public enum StatusGlyph {
    static func symbol(for state: SwitchboardState) -> (name: String, tint: Tint)
}   // on rectangle.split.1x2, off rectangle, unknown questionmark.square.dashed;
    // red when lastError is set (outranks), secondary when the DualUp is unreachable, else primary

public struct RunProgress: Equatable, Sendable {   // reduces RunEvents for the run row
    enum Outcome { case none, finished, failed }
    private(set) var id: String?, runID: String?, isRunning: Bool, currentStep: Int, stepCount: Int
    private(set) var lastMessage: String, lastOutcome: Outcome
    mutating func apply(_ event: RunEvent);  mutating func reject(id: String, message: String)
    var fraction: Double;  var statusLine: String
}   // events of another run than the one in progress are ignored; `started` always begins a new run

public struct RunOutcome: Sendable, Equatable {
    enum Status { case finished, failed, rejected }  // rejected: never started (unknown id, bad parameter, busy)
    var id: String, status: Status, message: String, report: RunReport?;  var succeeded: Bool
}

@MainActor @Observable public final class AppModel {
    typealias RuntimeFactory = @MainActor (Settings, StateStore, @escaping @Sendable (String) async -> Void) -> Runtime
    typealias Discovery = @Sendable (Duration) async -> DiscoveredController?
    init(environment: [String: String] = ProcessInfo.processInfo.environment, supportDirectory: URL? = nil,
         runtimeFactory: RuntimeFactory? = nil,                       // default: Runtime.live
         notifier: any UserNotifier = SystemNotifier(), loginItem: any LaunchAtLoginService = MainAppLoginItem(),
         discovery: @escaping Discovery = { await ESP32Discovery.first(timeout: $0) })

    private(set) var runtime: Runtime, settings: Settings, macros: [Macro], macrosError: String?, startupError: String?
    private(set) var runProgress: RunProgress, isBusy: Bool, launchAtLoginStatus: LaunchAtLoginStatus, launchAtLoginMessage: String?
    var state: SwitchboardState { runtime.store.state }              // mirrors the store
    var log: [LogEntry] { runtime.store.log }
    var actions: [ActionDescriptor] { runtime.registry.descriptors }
    var controllerURL: URL?;  var controllerURLComesFromEnvironment: Bool
    let supportDirectory: URL, environment: [String: String]

    func start() async                  // idempotent: settings.json, macros.json, refresher, services
    func stop()                         // stops polling
    func run(id: String, parameters: [String: JSONValue] = [:]) async -> RunOutcome      // MacroRunner.execute
    func run(_ action: ActionID, parameters: [String: JSONValue] = [:]) async -> RunOutcome
    func resyncHDMI(display: DisplayID, input: Int) async -> RunOutcome                  // hdmi.resync
    func handle(url: URL) async -> RunOutcome?                       // parse + run; failures become notifications
    func saveSettings(_ settings: Settings) async throws             // SettingsError
    func discoverController(timeout: Duration = .seconds(3)) async -> DiscoveredController?
    func setLaunchAtLogin(_ enabled: Bool) async -> String?          // message when something needs the user
    func openLoginItemsSettings()
    func reloadMacros() async;  func saveMacros(_ macros: [Macro]) async throws          // MacroStoreError
    func notify(_ text: String) async                                // UNUserNotification, else the log

    // MARK: Services
    func startServices()    // empty: tracer bullet 5 starts the local API here
}

// Editor and window helpers (pure)
public struct StepDraft, VerifyDraft, MacroDraft;  public enum MacroDraftSet   // text-field drafts of a Macro
    // MacroDraft.issues(among:) uses MacroValidator.isValidID, ActionRegistry.validate and the verify ranges, plus
    // "every parameter of the descriptor is filled in"; a list without issues is accepted by MacroStore.save.
public struct SettingsDraft                                          // text fields -> Settings via Settings.set(_:to:)
public enum LogPresentation, RelativeTime                            // log filter/copy text, "5 s ago"
public protocol LaunchAtLoginService { status; register(); unregister(); openSystemSettings() }   // MainAppLoginItem = SMAppService.mainApp
public protocol UserNotifier { func post(title: String, body: String) async -> NotificationOutcome }   // SystemNotifier
```

Behaviour worth knowing before building on it:

- `init` builds a `Runtime` from default settings (no hardware is touched), `start()` loads `settings.json`
  and rebuilds the runtime if it differs, loads `macros.json` (writing the defaults on first launch),
  refreshes the login item status, starts the `StateRefresher` and calls `startServices()`. A
  `settings.json` or `macros.json` that cannot be read leaves the defaults / no macros, sets
  `startupError` / `macrosError`, logs it and is never overwritten by `start()`; the macro editor refuses to
  save while `macrosError` is set (Reload after fixing the file by hand).
- The `StateStore` outlives the runtime: `saveSettings` rebuilds the `Runtime` (through the factory, with the
  same store) when `controllerURL`, `displayNameContains`, `pollingIntervalSeconds` or `localAPIPort`
  changed, so the log and the last reading carry over. A rebuild while a run is in progress waits for
  the run to end. **Services hook:** `startServices()` runs at the end of `start()` and again after every
  rebuild; tracer bullet 5 must stop what it started before starting again, and must take
  `runtime.runner`, `runtime.macros` and `runtime.registry` from `model.runtime` afresh, because a rebuild
  replaces them. (Nothing else in the app starts a server, a token or a listener.)
- One run at a time through the UI: `run` while `isBusy`, or while someone else's run holds the runner
  (`ActionError.busy`), is `rejected` and leaves the progress of the run in progress alone. `runProgress`
  is fed from the runner's events in order. A run that fails sets the store's `lastError`; a run that
  is rejected (unknown id, bad parameter) only shows in the run row and the log.
- `handle(url:)` awaits `start()` first, so a URL that launches the app runs after the macros are loaded. A
  URL that does not parse, and a run that does not finish, post a notification (a run that works is
  quiet). `SwitchboardApp` installs `NSApplicationDelegate.application(_:open:)` for the URLs, declared in
  `App/Info.plist` (`CFBundleURLTypes`, scheme `switchboard`, role Viewer). Every scene carries
  `.handlesExternalEvents(matching: [])`: without it SwiftUI opens one of the windows for each URL.
- Notifications ask for permission the first time one is posted, not at launch. Outside a bundle
  `UNUserNotificationCenter` cannot be used (it raises), so `SystemNotifier` reports `skipped` and the text goes
  to the log; `MainAppLoginItem` reports `notInBundle` and `setLaunchAtLogin` says to run the `.app`.
- The in-app log is also written to `os.Logger` (subsystem `io.github.fgiannazzo.switchboard`, category `app`)
  for what `AppModel` itself does (start, settings, URLs, launch at login); the runner's own lines stay in
  the in-app log only. There is no `log.txt` yet.
- The launch-at-login toggle shows `SMAppService.mainApp.status` (on while approval is pending), not
  `settings.launchAtLogin`, which only records what the system last said.
- The status item image is a template (`primary`), a template at 45 % opacity (`secondary`) or a red
  non-template symbol (`red`): only red is a real colour in the menu bar.

Deviations from the brief and from the first draft of this file, recorded in tracer bullet 4:
`Runtime.live` gained a `store:` parameter (default a new store) so a rebuild keeps the log; the runtime is
rebuilt for `pollingIntervalSeconds` and `localAPIPort` too (the first because the refresher takes its
interval at construction, the second so services restart on a port change); `AppModel.run` returns a
`RunOutcome` rather than the runner's `RunReport` (a run that never started has no report);
`SwitchboardURL.parse` does not validate action parameters (the runner does; see above);
`Info.plist` has no `NSUserNotificationsUsageDescription` (macOS has no such key; permission is asked at
first use) and does have `NSAppTransportSecurity`/`NSAllowsLocalNetworking` for the controller's plain HTTP
and a `CFBundleIconFile` for the icon that `Scripts/make-icon.swift` draws at build time; `make run-app` opens
an existing bundle and does not build one; the macro editor requires a non-empty name, which the store
does not.

## LocalAPI (tracer bullet 5, final)

The wire contract is `docs/API.md`; clients (the CLI, the generated wrappers, the Stream Deck plugin)
are built against that file. `Sources/LocalAPI` depends on `TinyHTTP`, `Actions`, `StateStore` and
`SwitchboardCore`.

In the app the server lives in `AppModel` (`AppCore` depends on `LocalAPI`): `startServices()` stops
the previous `LocalAPIServer`, reads the token through the injected `TokenStoring` (the keychain in
the app, a `FileTokenStore` in tests), and starts a new server on `settings.localAPIPort` over the
current `Runtime`; it runs at the end of `start()` and after every runtime rebuild, so a port change
saved in Settings restarts the server. `apiStatus: APIStatus` (`stopped`, `starting`, `running(URL)`,
`failed(String)`) and `apiToken` are observable for the Settings pane; `stopServices()`/`shutdown()`
take it down and wait for the port. A failure to start (port in use, keychain denied) is shown and
logged; the rest of the app keeps working.

```swift
public enum SwitchboardVersion { static let current = "0.1.0" }     // the one place; GET /health, `switchboardctl --version`

// Token
public protocol TokenStoring: Sendable { func load() throws -> String?; func save(_ token: String) throws }
public struct KeychainTokenStore: TokenStoring {     // generic password, login keychain, no data-protection keychain
    init(service: String = TokenStore.service, account: String = TokenStore.account)
    func delete() throws                             // tests only
}
public struct FileTokenStore: TokenStoring { init(url: URL) }   // mode 0600, directory 0700
public enum TokenStore {
    static let service = "io.github.fgiannazzo.switchboard", account = "local-api-token", byteCount = 32
    static func generate() throws -> String          // 32 bytes from SecRandomCopyBytes, base64url, no padding: 43 chars
    static func loadOrCreate(using: some TokenStoring) throws -> String
    static func resolve(using: some TokenStoring) throws -> (token: String, created: Bool)
    static func constantTimeEquals(_: String, _: String) -> Bool
}
public enum TokenStoreError: Error { keychain(status: Int32, detail: String), corrupt(String), file(path: String, detail: String), randomFailure(Int32) }

// Server
public actor LocalAPIServer {
    init(runtime: Runtime, port: UInt16, token: String, version: String = SwitchboardVersion.current,
         host: String = "127.0.0.1", keepaliveInterval: Duration = .seconds(15))
    static func start(runtime: Runtime, tokenStore: some TokenStoring = KeychainTokenStore(),
                      version: String = SwitchboardVersion.current) async throws -> LocalAPIServer
    func start() async throws;  func stop() async
    private(set) var port: UInt16                    // the bound port after start(); the requested one before and after
    var isRunning: Bool, activeConnectionCount: Int, url: URL?       // async getters
    nonisolated let host: String, version: String, requestedPort: UInt16
}
public enum LocalAPIServerError: Error { invalidPort(Int) }

// Client
public struct LocalAPIClient: Sendable {
    static let defaultBaseURL = http://127.0.0.1:48600;  static func baseURL(port: Int) -> URL
    init(baseURL: URL = defaultBaseURL, token: String?, timeout: TimeInterval = 5, session: URLSession? = nil)
    func health() async throws -> HealthResponse                       // no token sent
    func state() async throws -> SwitchboardState
    func actions() async throws -> ActionList;  func macros() async throws -> MacroFile
    func run(id: String, parameters: [String: JSONValue] = [:]) async throws -> RunHandle
    func events() -> AsyncThrowingStream<APIEvent, any Error>           // SSEParser.events(from:); does not reconnect
}
public enum APIEvent: Sendable, Equatable { case state(SwitchboardState), run(RunEvent) }
public enum LocalAPIError: Error, Sendable, Equatable {
    case unreachable(URL, underlying: String), unauthorized, status(Int, body: String), invalidResponse(String)
    var errorBody: APIErrorBody?, isUnreachable: Bool
}
public struct HealthResponse: Codable { ok: Bool, name: String, version: String }
public struct APIErrorBody: Codable { error: String, id/parameter/reason/runId: String? }

// JSON, wrappers, failure kinds
public enum APIJSON {       // sorted keys, no spaces, dates "2026-10-11T20:15:03.120Z"
    static func makeEncoder() -> JSONEncoder;  static func makeDecoder() -> JSONDecoder
    static func string(from: Date) -> String;  static func date(from: String) -> Date?;  static let neverUpdated: String
}
public enum StreamDeckWrappers {
    static func generate(into directory: URL, macros: [Macro], actions: [ActionDescriptor],
                         switchboardctlPath: String) throws -> [URL]   // sorted wrapper files; README.txt is written too
}
public enum RunFailureKind { unverifiedWrite, controllerUnreachable, other }
extension RunEvent { var failureKind: RunFailureKind? }                 // nil unless status == .failed
```

Behaviour worth knowing before building on it:

- **Auth first.** One check in front of the router: everything except `GET /health` (and `HEAD`) needs
  `Authorization: Bearer <token>`, compared in constant time; the query string is never read. An unknown
  path or a wrong method without a token is `401` as well; with a token they are 404 and 405. An empty
  server token authenticates nobody.
- **Bind.** `127.0.0.1` only (`host` exists for tests). `start()` throws when the port is taken.
- **Main actor.** `GET /state` reads `runtime.store.state` with one hop to the main actor; `/events` takes
  `runtime.store.changes` and `runtime.runner.events` the same way. Nothing else in the server is
  main-actor bound.
- **`POST /run/{id}`** parses an optional JSON object body into `[String: JSONValue]` and calls
  `runner.start`; `ActionError.unknownID` is 404, `.missingParameter` and `.invalidParameter` are 400,
  `.busy` is 409 with the running `runId`, any other error 500. The run itself is never awaited: the
  `202` carries the `RunHandle` and progress arrives on `/events`.
- **`GET /events`** subscribes to `runner.events` first, then to `store.changes` (whose first element is
  the current state, the connect-time `state` event), and forwards both on one connection plus a
  `: keepalive` comment every `keepaliveInterval`. The producer is a task group; `TinyHTTP` cancels the
  producer when the client disconnects, which cancels the three forwarders and, through the streams'
  termination handlers, removes both subscriptions. A test pins that `subscriberCount` of the store and
  the runner and the server's connection count all return to 0.
- **Dates.** `JSONEncoder`'s `.iso8601` has no milliseconds and `ISO8601DateFormatter` truncates binary
  fractions (`x.12` can print `.119`), so `APIJSON` formats and parses by hand (civil-date arithmetic,
  rounded to the millisecond). `Date.distantPast`, a state's `updatedAt` before its first update, is
  written `0001-01-01T00:00:00.000Z` and read back as `.distantPast`.
- **The client** sends the token on every request but `/health`, uses an ephemeral session without
  proxies, maps transport errors to `.unreachable`, 401 to `.unauthorized`, any other non-2xx to
  `.status`, and gives `events()` a 45 s silence limit (`docs/API.md`). Unknown event names are ignored.
- **The CLI** finds the app by `GET /health` within 300 ms and a `name` of `Switchboard`, then reads the token
  (keychain, or `SWITCHBOARD_TOKEN_FILE`). To follow a run it opens `/events`, waits for the first `state`
  event, then `POST`s the run and prints the events with its `runId`.
- **Wrappers.** One `<id>.command` per macro and per parameter-free action (a macro wins over an action with
  the same id), `#!/bin/bash` plus `exec "<switchboardctl>" run <id>`, mode 0755, and a `README.txt`. A
  file that is already right is not rewritten; nothing is deleted; ids that are not safe file names or that
  differ only in case are refused before anything is written.

The URL scheme has no token (it is OS-mediated and only reaches the app); it is the app's, tracer
bullet 4.

Deviations from the first draft of this section, recorded in tracer bullet 5: `LocalAPIServer.start(runtime:)`
and `keepaliveInterval` were added; `switchboardctl serve --poll` starts the `StateRefresher` (reads only)
and `SWITCHBOARD_TOKEN_FILE` swaps the keychain for a file, both for development; `SwitchboardVersion` lives in
`LocalAPI`; the API gained the 400 `invalid parameter` and `invalid body` bodies, the `500` body, and the
`0001-01-01T00:00:00.000Z` spelling of a never-updated state, all documented in `docs/API.md`.

## Hardware rules for anyone, human or agent, working in this repository

1. The only hardware writes in the codebase are the two `LGDualUpCommand` cases. Adding a
   case needs a verified fact in `docs/BRIEF.md` first. Mechanically: `VCPWrite.init` is
   `package`, the only production construction is `LGDualUpCommand.write`, and the only
   production caller of `DDCTransport.write` is `LGDualUp.perform`. `grep -rn "VCPWrite(" Sources/`
   should keep returning that one line (plus the `description` string).
2. Never write 0xF4 on source 0x50. Never write 0x60. Never scan or probe.
3. Tests never touch hardware: `swift test` runs against `FakeDDC` and `MockESP32` only.
4. Verify after every write with a video-cable read and surface the result.
5. Subagents do not run `switchboardctl` or any binary against the real monitor at all.
   Hardware checks are run by Felipe from `docs/HARDWARE-CHECKLIST.md`.
6. If the hardware contradicts the brief, stop and report the raw bytes.
7. `displays.off` and `displays.on` are not monitor writes: they ask BetterDisplay to disconnect or
   connect displays in macOS. They still change what the people at the desk see, so agents do not
   run them; Felipe does (`docs/HARDWARE-CHECKLIST.md`, Check 7).
