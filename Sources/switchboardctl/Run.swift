import Actions
import Foundation
import StateStore
import SwitchboardCore

// `switchboardctl run | actions | macros | settings`: macros, actions and settings
// (docs/DESIGN.md, "Actions"). Same split as main.swift: the logic lives in Actions and
// StateStore (and is unit-tested there), this file parses arguments and formats output.
//
// `run` exit codes: 0 finished, 1 failed, 3 a monitor write was not verified, 6 the controller
// was not configured or not reachable, 7 another run is in progress.

let runHelp = """
      run <id> [key=value ...] [--json]
                                        run a macro, or an action with parameters, and print each
                                        run event as it happens (--json: one JSON object per
                                        line). Examples: run guest, run usb.select port=2.
                                        exit 0 finished, 1 failed, 3 monitor write unverified,
                                        6 controller unreachable, 7 busy
      actions [--json]                  list the actions and their parameters
      macros [--json]                   list the macros (macros.json; the defaults guest and solo
                                        are created on first use)
      settings show [--json]            print the settings
      settings set <key> <value>        change a setting; keys: controllerURL (http://host:port or
                                        none), displayNameContains, pollingIntervalSeconds,
                                        localAPIPort, launchAtLogin (true|false)
    """

// MARK: - Output

/// One line on stdout, written straight to the file descriptor so a pipe sees each run event as
/// it happens.
private func emit(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

private func jsonText<T: Encodable>(_ value: T, pretty: Bool) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

/// Accepts `--json` and nothing else.
private func parseJSONFlag(_ args: ArraySlice<String>) throws -> Bool {
    var json = false
    for arg in args {
        guard arg == "--json" else { throw CLIError("unknown option \(arg)\n\(usage)") }
        json = true
    }
    return json
}

// MARK: - run

/// The `run` exit code for a failure. Nil (a failed run with no recorded reason) is a plain error.
func runExitCode(for error: ActionError?) -> Int32 {
    guard let error else { return ExitCode.error }
    if error.isUnverifiedWrite { return ExitCode.unverified }
    if error.isControllerUnreachable { return ExitCode.controllerUnreachable }
    if error.isBusy { return ExitCode.busy }
    return ExitCode.error
}

func runCommand(_ args: ArraySlice<String>) async throws {
    var json = false
    var id: String?
    var text: [String: String] = [:]

    for arg in args {
        if arg == "--json" {
            json = true
        } else if arg.hasPrefix("--") {
            throw CLIError("unknown option \(arg)\n\(usage)")
        } else if id == nil {
            guard !arg.contains("=") else { throw CLIError("run needs a macro or action id first, got \(arg)\n\(usage)") }
            id = arg
        } else if let equals = arg.firstIndex(of: "="), equals != arg.startIndex {
            text[String(arg[..<equals])] = String(arg[arg.index(after: equals)...])
        } else {
            throw CLIError("parameters are written key=value, got \(arg)\n\(usage)")
        }
    }
    guard let id else { throw CLIError("run needs a macro or action id\n\(usage)") }

    let environment = ProcessInfo.processInfo.environment
    let directory = AppSupport.directory(environment: environment)
    let settings = try await SettingsStore(directory: directory).load()
    let runtime = await Runtime.live(settings: settings, environment: environment, appSupport: directory)

    // key=value text becomes typed parameters from the action's own descriptors. A macro ignores
    // them (docs/API.md).
    let parameters: [String: JSONValue]
    if let action = ActionID(rawValue: id) {
        parameters = runtime.registry.descriptor(for: action).parameters(fromText: text)
    } else {
        parameters = text.mapValues { .string($0) }
    }

    let asJSON = json
    let report: RunReport
    do {
        report = try await runtime.runner.execute(id: id, parameters: parameters) { event in
            if asJSON {
                if let line = try? jsonText(event, pretty: false) { emit(line) }
            } else {
                emit(event.line)
            }
        }
    } catch let error as ActionError {
        var message = "\(error)"
        if case .unknownID = error { message += "; see `switchboardctl actions` and `switchboardctl macros`" }
        throw CLIError(message, code: runExitCode(for: error))
    }

    // The failed event is already on stdout; only the exit code is left to say.
    if !report.succeeded { throw CLIError("", code: runExitCode(for: report.error)) }
}

// MARK: - actions / macros

func actionsCommand(_ args: ArraySlice<String>) throws {
    let json = try parseJSONFlag(args)
    let descriptors = ActionRegistry().descriptors
    if json {
        emit(try jsonText(ActionList(actions: descriptors), pretty: true))
        return
    }
    let width = descriptors.map { $0.id.rawValue.count }.max() ?? 0
    for descriptor in descriptors {
        let id = descriptor.id.rawValue.padding(toLength: width, withPad: " ", startingAt: 0)
        let signature = descriptor.signature
        emit("\(id)  \(descriptor.title)" + (signature.isEmpty ? "" : "  [\(signature)]"))
    }
}

func macrosCommand(_ args: ArraySlice<String>) async throws {
    let json = try parseJSONFlag(args)
    let directory = AppSupport.directory(environment: ProcessInfo.processInfo.environment)
    let macros = try await MacroStore(directory: directory).load()
    if json {
        emit(try jsonText(MacroFile(macros: macros), pretty: true))
        return
    }
    let width = macros.map { $0.id.count }.max() ?? 0
    for macro in macros {
        let id = macro.id.padding(toLength: width, withPad: " ", startingAt: 0)
        var line = "\(id)  \(macro.name)  " + macro.steps.map(\.summary).joined(separator: " -> ")
        if let verify = macro.verify, !verify.isEmpty { line += "  (verify \(verify.summary))" }
        emit(line)
    }
}

// MARK: - settings

func settingsCommand(_ args: ArraySlice<String>) async throws {
    let environment = ProcessInfo.processInfo.environment
    let store = SettingsStore(directory: AppSupport.directory(environment: environment))

    switch args.first {
    case "show":
        let json = try parseJSONFlag(args.dropFirst())
        let settings = try await store.load()
        if json {
            emit(try jsonText(settings, pretty: true))
            return
        }
        for key in Settings.Key.allCases {
            emit("\(key.rawValue): \(settings.text(for: key))")
        }
        if settings.controllerURLComesFromEnvironment(environment), let url = settings.effectiveControllerURL(environment: environment) {
            emit("controller in effect: \(url.absoluteString) (from \(Settings.controllerURLEnvironmentKey))")
        }
        let file = store.fileURL.path(percentEncoded: false)
        emit("file: \(file)" + (store.fileExists ? "" : " (not created yet; these are the defaults)"))

    case "set":
        let rest = Array(args.dropFirst())
        guard rest.count == 2 else { throw CLIError("usage: settings set <key> <value>\n\(usage)") }
        var settings = try await store.load()
        do {
            try settings.set(rest[0], to: rest[1])
        } catch let error as SettingsError {
            throw CLIError(error.description)
        }
        try await store.save(settings)
        if let key = Settings.Key(rawValue: rest[0]) {
            emit("\(key.rawValue) = \(settings.text(for: key))")
            if key == .controllerURL, settings.controllerURLComesFromEnvironment(environment) {
                FileHandle.standardError.write(Data("switchboardctl: \(Settings.controllerURLEnvironmentKey) is set in this environment and overrides the saved controllerURL\n".utf8))
            }
        }

    case let other?:
        throw CLIError("unknown settings command \(other); use show or set\n\(usage)")
    case nil:
        throw CLIError("settings needs show or set\n\(usage)")
    }
}
