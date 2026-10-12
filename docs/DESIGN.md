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

- Swift 6.4. Xcode is optional: the project must build from the Command Line Tools alone.
  Everything is SwiftPM: no `.xcodeproj`, no `xcodebuild`.
- `// swift-tools-version: 6.0`, `platforms: [.macOS(.v15)]`, Swift 6 language mode on every target.
- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`). XCTest is not available
  without Xcode, so never import it; Swift Testing works in both setups.
- The Command Line Tools' SwiftPM (Swift 6.4, Swift Build backend) does not pass the Swift
  Testing macro plugin directory to the compiler, so `@Test` fails to expand. `Package.swift`
  locates the toolchain that is evaluating the manifest and adds
  `-plugin-path <toolchain>/usr/lib/swift/host/plugins/testing` to the test targets. Xcode's
  toolchain adds the same path itself; the duplicate is harmless. Remove the workaround once a
  toolchain update makes plain `swift test` work without it.
- The app bundle is assembled by `Scripts/make-app.sh` from the SwiftPM executable plus
  `App/Info.plist`, then ad-hoc signed (`codesign -s -`). `make app` wraps it.
- No third-party dependencies in the Swift package. The Stream Deck plugin (TypeScript, in
  `StreamDeckPlugin/`) is a separate npm package and may use the Elgato SDK.
- Verification for every PR: `swift build && swift test`.

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
directly for `monitor list` and `monitor read`; from tracer bullet 5 on it talks to the API.

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
public actor FakeDDC: DDCTransport         // records writes, serves scripted reads, for tests

public enum DDCError: Error { displayNotFound(String), ioKit(Int32, operation: String), invalidReply([UInt8]), readUnsupported, noReply, invalidEDID(String) }

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

## Devices.LGDualUp

```swift
public enum LGDualUpCommand: String, CaseIterable, Sendable, Codable {
    case pbpOn      // USB bridge only, 0xD7 = 0, expect read-back 0 on the video cable
    case pbpOff     // video cable only, 0xD7 = 1, expect read-back 1
}
public struct WriteOutcome: Sendable, Equatable { command, transport: String, expected: UInt16, observed: UInt16?, verified: Bool }
public enum DualUpCode { static let pbp: UInt8 = 0xD7; static let mainInput: UInt8 = 0xF5 }
public struct DualUpReading: Sendable, Equatable { pbp: PBPState, mainInput: MainInput, raw: [UInt8: UInt16] }
public actor LGDualUp {
    init(videoCable: any DDCTransport, usbBridge: any DDCTransport, sleep: @escaping Sleeper = Timing.realSleep)
    func perform(_ command: LGDualUpCommand) async throws -> WriteOutcome   // write, settle, double-read 0xD7, compare
    func readState() async -> DualUpReading   // 0xD7 and 0xF5 via StableReader; never throws, unreadable = .unknown
}
```

Tracer bullet 1 ships `init(videoCable:sleep:)` and `readState()`; `usbBridge`,
`LGDualUpCommand`, `WriteOutcome` and `perform` arrive with the whitelist in tracer bullet 2.
`readState` does not throw: a code that cannot be read stably is `.unknown` and absent from
`raw`. Whether the display is connected at all is a separate question (`VideoCableDDC.display()`
throws `DDCError.displayNotFound`), which is how `switchboardctl` tells exit code 2 apart.

`perform` never reports success from the write alone. `observed == nil` means unknown, and
`verified == false`; the caller surfaces that as "unverified", not as failure of the monitor.

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
   case needs a verified fact in `docs/BRIEF.md` first.
2. Never write 0xF4 on source 0x50. Never write 0x60. Never scan or probe.
3. Tests never touch hardware: `swift test` runs against `FakeDDC` and `MockESP32` only.
4. Verify after every write with a video-cable read and surface the result.
5. Subagents do not run `switchboardctl` or any binary against the real monitor at all.
   Hardware checks are run by Felipe from `docs/HARDWARE-CHECKLIST.md`.
6. If the hardware contradicts the brief, stop and report the raw bytes.
