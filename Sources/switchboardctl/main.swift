import DDCKit
import Devices
import Foundation
import SwitchboardCore

// switchboardctl: thin CLI over the Switchboard libraries. Logic lives in DDCKit and Devices;
// this file only parses arguments and formats output.
//
// Exit codes: 0 ok, 1 error, 2 display not found, 3 write unverified, 4 USB bridge not found,
// 5 USB bridge busy (held exclusively by another client).

enum ExitCode {
    static let ok: Int32 = 0
    static let error: Int32 = 1
    static let displayNotFound: Int32 = 2
    static let unverified: Int32 = 3
    static let bridgeNotFound: Int32 = 4
    static let bridgeBusy: Int32 = 5
}

let usage = """
    usage: switchboardctl <command> [options]

    commands:
      monitor list                      list external displays (EDID name, serial, serial string)
      monitor read [--display NAME] [--json]
                                        read the LG DualUp's PBP (0xD7) and main input (0xF5)
                                        over the video cable
      monitor pbp on|off [--display NAME] [--json] [--dry-run]
                                        switch picture-by-picture: `on` writes 0xD7 = 0 over the
                                        USB HID bridge, `off` writes 0xD7 = 1 over the video
                                        cable; both wait 4 s and verify by reading 0xD7 back
                                        over the video cable. --dry-run prints the exact bytes
                                        and touches nothing.
      monitor bridge list               list LG USB HID bridge interfaces (vendor 0x043E)
      monitor bridge reset              re-enumerate the LG USB bridge (when it has gone quiet)
      --help, -h, help                  this text

    NAME is a case-insensitive substring of the display's EDID name (default SDQHD, the DualUp).

    exit codes: 0 ok, 1 error, 2 display not found, 3 write unverified, 4 USB bridge not found,
                5 USB bridge busy
    """

struct CLIError: Error, CustomStringConvertible {
    let description: String
    let code: Int32
    init(_ description: String, code: Int32 = ExitCode.error) {
        self.description = description
        self.code = code
    }
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data("switchboardctl: \(message)\n".utf8))
}

// MARK: - Argument parsing

struct Options {
    var display = "SDQHD"
    var json = false
    var dryRun = false
}

func parseOptions(_ args: ArraySlice<String>, allowDryRun: Bool = false) throws -> Options {
    var options = Options()
    var iterator = args.makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--json":
            options.json = true
        case "--dry-run" where allowDryRun:
            options.dryRun = true
        case "--display":
            guard let value = iterator.next(), !value.isEmpty else { throw CLIError("--display needs a value") }
            options.display = value
        case _ where arg.hasPrefix("--display="):
            let value = String(arg.dropFirst("--display=".count))
            guard !value.isEmpty else { throw CLIError("--display needs a value") }
            options.display = value
        default:
            throw CLIError("unknown option \(arg)\n\(usage)")
        }
    }
    return options
}

/// Maps the DDCKit errors that have an exit code of their own; everything else stays exit 1.
func cliError(from error: any Error) -> any Error {
    guard let ddc = error as? DDCError else { return error }
    switch ddc {
    case .displayNotFound:
        return CLIError("\(ddc). Run `switchboardctl monitor list`.", code: ExitCode.displayNotFound)
    case .bridgeNotFound:
        return CLIError("\(ddc) Run `switchboardctl monitor bridge list`.", code: ExitCode.bridgeNotFound)
    case .bridgeBusy:
        return CLIError("\(ddc)", code: ExitCode.bridgeBusy)
    default:
        return ddc
    }
}

// MARK: - monitor list / read

func monitorList() throws {
    let displays = try DisplayEnumerator.externalDisplays()
    if displays.isEmpty {
        print("no external displays")
        return
    }
    for display in displays {
        print(display.description)
    }
}

struct ReadOutput: Encodable {
    let display: String
    let serial: String
    let pbp: PBPState
    let mainInput: MainInput
    let raw: [String: UInt16]
}

func describe(_ value: UInt16?, meaning: String?) -> String {
    guard let value else { return "unknown (unreadable)" }
    if let meaning { return "\(value) (\(meaning))" }
    return "\(value) (unexpected value)"
}

func pbpMeaning(_ state: PBPState) -> String? {
    switch state {
    case .on: return "on"
    case .off: return "off"
    case .unknown: return nil
    }
}

func mainInputMeaning(_ input: MainInput) -> String? {
    switch input {
    case .hdmi1: return "HDMI 1"
    case .hdmi2: return "HDMI 2"
    case .unknown: return nil
    }
}

func encodeJSON(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

func monitorRead(_ options: Options) async throws {
    let cable = VideoCableDDC(displayNameContains: options.display)
    let display = try await cable.display()
    let dualUp = LGDualUp(videoCable: cable)
    let reading = await dualUp.readState()

    if options.json {
        var raw: [String: UInt16] = [:]
        for (code, value) in reading.raw {
            raw[DualUpReading.key(for: code)] = value
        }
        let output = ReadOutput(display: display.name, serial: display.serialHex, pbp: reading.pbp, mainInput: reading.mainInput, raw: raw)
        print(try encodeJSON(output))
        return
    }

    print("display: \(display.name)  serial \(display.serialHex)")
    print("0xD7 PBP: \(describe(reading.raw[DualUpCode.pbp], meaning: pbpMeaning(reading.pbp)))")
    print("0xF5 main input: \(describe(reading.raw[DualUpCode.mainInput], meaning: mainInputMeaning(reading.mainInput)))")
}

// MARK: - monitor pbp

func monitorPBP(_ command: LGDualUpCommand, _ options: Options) async throws {
    if options.dryRun {
        // Formatting only: no transport is constructed and IOKit is never touched.
        for line in DryRunFormatter.lines(for: command, displayNameContains: options.display) {
            print(line)
        }
        return
    }

    let cable = VideoCableDDC(displayNameContains: options.display)
    let bridge = LGUSBBridge(displayNameContains: options.display)
    let dualUp = LGDualUp(videoCable: cable, usbBridge: bridge)

    let transport: any DDCTransport = command.transport == .usbBridge ? bridge : cable
    if !options.json {
        print("transport: \(transport.name)")
        print("writing 0x\(DDCPacket.hexString([command.code])) = \(command.value), then waiting \(Timing.settleAfterModeChange) for the link to settle")
    }

    let outcome = try await dualUp.perform(command)

    if options.json {
        print(try encodeJSON(outcome))
    } else {
        let code = "0x" + DDCPacket.hexString([outcome.command.code])
        if outcome.verified {
            print("verified: \(code) = \(outcome.expected) (\(command.targetState.rawValue))")
        } else if let observed = outcome.observed {
            print("UNVERIFIED: \(code) read back \(describe(observed, meaning: pbpMeaning(outcome.reading.pbp)))")
        } else {
            print("UNVERIFIED: \(code) unreadable")
        }
    }
    guard outcome.verified else {
        throw CLIError("write not verified by the video-cable read-back", code: ExitCode.unverified)
    }
}

// MARK: - monitor bridge

func bridgeList() throws {
    let devices = try LGUSBBridge.listDevices()
    guard !devices.isEmpty else {
        throw CLIError("no LG USB bridge (vendor 0x043E, product 0x9A39) present; \(DDCError.bridgeHint)", code: ExitCode.bridgeNotFound)
    }
    for device in devices {
        print(device.description)
    }
}

func bridgeReset() throws {
    let count = try USBReenumerator.reenumerateLGBridge()
    guard count > 0 else {
        throw CLIError("no LG USB bridge (vendor 0x043E, product 0x9A39) to re-enumerate; \(DDCError.bridgeHint)", code: ExitCode.bridgeNotFound)
    }
    print("re-enumerated \(count) LG USB device\(count == 1 ? "" : "s"); give it a few seconds, then `switchboardctl monitor bridge list`")
}

// MARK: - Entry point

func run(_ arguments: [String]) async -> Int32 {
    let args = arguments.dropFirst()
    guard let command = args.first else {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        return ExitCode.error
    }

    do {
        do {
            switch command {
            case "--help", "-h", "help":
                print(usage)
            case "monitor":
                try await runMonitor(args.dropFirst())
            default:
                throw CLIError("unknown command \(command)\n\(usage)")
            }
        } catch let error as DDCError {
            throw cliError(from: error)
        }
        return ExitCode.ok
    } catch let error as CLIError {
        printError(error.description)
        return error.code
    } catch {
        printError("\(error)")
        return ExitCode.error
    }
}

func runMonitor(_ rest: ArraySlice<String>) async throws {
    switch rest.first {
    case "list":
        guard rest.count == 1 else { throw CLIError("monitor list takes no options") }
        try monitorList()
    case "read":
        try await monitorRead(try parseOptions(rest.dropFirst()))
    case "pbp":
        let after = rest.dropFirst()
        let command: LGDualUpCommand
        switch after.first {
        case "on": command = .pbpOn
        case "off": command = .pbpOff
        case let other?: throw CLIError("monitor pbp takes on|off, not \(other)\n\(usage)")
        case nil: throw CLIError("monitor pbp needs on|off\n\(usage)")
        }
        try await monitorPBP(command, try parseOptions(after.dropFirst(), allowDryRun: true))
    case "bridge":
        let after = rest.dropFirst()
        guard after.count == 1 else { throw CLIError("monitor bridge takes exactly one of list|reset\n\(usage)") }
        switch after.first {
        case "list": try bridgeList()
        case "reset": try bridgeReset()
        case let other?: throw CLIError("unknown monitor bridge command \(other)\n\(usage)")
        case nil: throw CLIError("monitor bridge needs list|reset\n\(usage)")
        }
    case let sub?:
        throw CLIError("unknown monitor command \(sub)\n\(usage)")
    case nil:
        throw CLIError("monitor needs a subcommand\n\(usage)")
    }
}

exit(await run(CommandLine.arguments))
