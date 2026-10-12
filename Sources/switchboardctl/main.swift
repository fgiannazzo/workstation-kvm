import DDCKit
import Devices
import Foundation
import SwitchboardCore

// switchboardctl: thin CLI over the Switchboard libraries. Logic lives in DDCKit and Devices;
// this file only parses arguments and formats output.
//
// Exit codes: 0 ok, 1 error, 2 display not found.

enum ExitCode {
    static let ok: Int32 = 0
    static let error: Int32 = 1
    static let displayNotFound: Int32 = 2
}

let usage = """
    usage: switchboardctl <command> [options]

    commands:
      monitor list                      list external displays (EDID name, serial, serial string)
      monitor read [--display NAME] [--json]
                                        read the LG DualUp's PBP (0xD7) and main input (0xF5)
                                        over the video cable; NAME is an EDID-name substring
                                        (default SDQHD)
      --help, -h, help                  this text

    exit codes: 0 ok, 1 error, 2 display not found
    """

struct CLIError: Error, CustomStringConvertible {
    let description: String
    let code: Int32
    init(_ description: String, code: Int32 = ExitCode.error) {
        self.description = description
        self.code = code
    }
}

func fail(_ message: String, code: Int32 = ExitCode.error) -> Never {
    FileHandle.standardError.write(Data("switchboardctl: \(message)\n".utf8))
    exit(code)
}

// MARK: - Argument parsing

struct Options {
    var display = "SDQHD"
    var json = false
}

func parseOptions(_ args: ArraySlice<String>) throws -> Options {
    var options = Options()
    var iterator = args.makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--json":
            options.json = true
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

// MARK: - Commands

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

func monitorRead(_ options: Options) async throws {
    let cable = VideoCableDDC(displayNameContains: options.display)
    let display: ExternalDisplay
    do {
        display = try await cable.display()
    } catch let error as DDCError {
        if case .displayNotFound = error {
            throw CLIError("\(error). Run `switchboardctl monitor list`.", code: ExitCode.displayNotFound)
        }
        throw error
    }

    let dualUp = LGDualUp(videoCable: cable)
    let reading = await dualUp.readState()

    if options.json {
        var raw: [String: UInt16] = [:]
        for (code, value) in reading.raw {
            raw["0x" + String(code, radix: 16, uppercase: true)] = value
        }
        let output = ReadOutput(display: display.name, serial: display.serialHex, pbp: reading.pbp, mainInput: reading.mainInput, raw: raw)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(output), as: UTF8.self))
        return
    }

    let pbpMeaning: String? = switch reading.pbp {
    case .on: "on"
    case .off: "off"
    case .unknown: nil
    }
    let inputMeaning: String? = switch reading.mainInput {
    case .hdmi1: "HDMI 1"
    case .hdmi2: "HDMI 2"
    case .unknown: nil
    }
    print("display: \(display.name)  serial \(display.serialHex)")
    print("0xD7 PBP: \(describe(reading.raw[DualUpCode.pbp], meaning: pbpMeaning))")
    print("0xF5 main input: \(describe(reading.raw[DualUpCode.mainInput], meaning: inputMeaning))")
}

// MARK: - Entry point

func run(_ arguments: [String]) async -> Int32 {
    let args = arguments.dropFirst()
    guard let command = args.first else {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        return ExitCode.error
    }

    do {
        switch command {
        case "--help", "-h", "help":
            print(usage)
        case "monitor":
            let rest = args.dropFirst()
            switch rest.first {
            case "list":
                guard rest.count == 1 else { throw CLIError("monitor list takes no options") }
                try monitorList()
            case "read":
                try await monitorRead(try parseOptions(rest.dropFirst()))
            case let sub?:
                throw CLIError("unknown monitor command \(sub)\n\(usage)")
            case nil:
                throw CLIError("monitor needs a subcommand\n\(usage)")
            }
        default:
            throw CLIError("unknown command \(command)\n\(usage)")
        }
        return ExitCode.ok
    } catch let error as CLIError {
        FileHandle.standardError.write(Data("switchboardctl: \(error.description)\n".utf8))
        return error.code
    } catch {
        FileHandle.standardError.write(Data("switchboardctl: \(error)\n".utf8))
        return ExitCode.error
    }
}

exit(await run(CommandLine.arguments))
