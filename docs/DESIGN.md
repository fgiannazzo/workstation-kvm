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
  StateStore/           @MainActor @Observable StateStore and its refresh sources.
  Actions/              Action registry, Macro model, MacroStore (JSON), MacroRunner.
  LocalAPI/             HTTP API, bearer auth, SSE events, Stream Deck wrapper generator.
  switchboardctl/       CLI executable.
  SwitchboardApp/       Menu bar app executable (SwiftUI MenuBarExtra).
Tests/
  DDCKitTests/ DevicesTests/ TinyHTTPTests/ ESP32KitTests/ ActionsTests/ LocalAPITests/
App/Info.plist          LSUIElement, CFBundleURLTypes for switchboard://
Scripts/make-app.sh
StreamDeckPlugin/       Phase 2, npm package.
docs/                   BRIEF.md, DESIGN.md, HARDWARE-CHECKLIST.md, STREAMDECK.md, API.md
```

Dependency direction (arrows mean "depends on"):

```
switchboardctl, SwitchboardApp -> LocalAPI -> Actions -> Devices -> DDCKit -> IOAVServiceShim
                                   |            |                     \-> USBReenumerate
                                   |            +-> StateStore -> SwitchboardCore
                                   +-> TinyHTTP          ESP32Kit -> TinyHTTP, SwitchboardCore
Devices, DDCKit -> SwitchboardCore   (PBPState, MainInput)
```

`SwitchboardCore` has no dependencies and no I/O. Nothing depends on an executable.

Until `LocalAPI` exists (tracer bullet 5), `switchboardctl` links `Devices` and `DDCKit`
directly for `monitor list`, `monitor read`, `monitor pbp on|off` and `monitor bridge list|reset`;
from tracer bullet 5 on it talks to the API.

`switchboardctl` exit codes: 0 ok, 1 error, 2 display not found (`DDCError.displayNotFound`),
3 write unverified (`WriteOutcome.verified == false`), 4 USB bridge not found
(`DDCError.bridgeNotFound`), 5 USB bridge busy (`DDCError.bridgeBusy`). `--dry-run` on
`monitor pbp` prints the bytes from `Devices.DryRunFormatter` and constructs no transport.

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

## Actions

Action ids (strings, stable, used by the API and the Stream Deck):
`monitor.pbp.on`, `monitor.pbp.off`, `monitor.read`, `hdmi.select`, `hdmi.resync`,
`usb.select`, `delay`, `notify`.

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

`ActionRegistry` resolves an id plus parameters to an `Action` and runs it against an
`ActionContext { dualUp: LGDualUp?, controller: (any ControllerClient)?, store: StateStore,
notify: (String) -> Void }`. With no controller configured, `hdmi.*` and `usb.*` throw
`ActionError.controllerUnavailable` with a message that names the setting to fix.
`POST /run/{id}` and `switchboardctl run {id}` accept a macro id or a parameter-free
action id.

## LocalAPI

The wire contract is `docs/API.md`; clients are built against that file.

`GET /state` (SwitchboardState), `GET /actions`, `GET /macros`, `POST /run/{id}` (optional
JSON body with parameters; 202 with a run id, result pushed on `/events`), `GET /events`
(server-sent events: `state` and `run` events). Every request needs
`Authorization: Bearer <token>`; the token is generated on first launch and stored in the
keychain; `switchboardctl token` prints it. Bind `127.0.0.1` only. The URL scheme has no
token (it is OS-mediated and only reaches the app).

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
