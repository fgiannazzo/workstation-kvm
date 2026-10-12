import Actions
import Foundation
import LocalAPI
import StateStore
import SwitchboardCore

// `switchboardctl state | events | token | serve | streamdeck export`, and the API side of
// `run`, `actions` and `macros` (docs/API.md). Same split as the other files: the logic lives in
// LocalAPI (and is unit-tested there); this file parses arguments, finds the app and formats output.
//
// Exit code 8 means "the Switchboard app is not running": no API answered on the port. `run`,
// `actions` and `macros` never exit 8, they fall back to doing the work in process.

let apiHelp = """
      state [--json] [--port N]         the app's current state (PBP, main input, USB port, HDMI
                                        inputs, reachability, last error), read through the local
                                        API. exit 8 when the app is not running
      events [--json] [--port N]        print the app's state and run events, one line each, until
                                        Ctrl-C (--json: {"event":"state"|"run","data":{...}})
      token                             print the local API bearer token, creating it in the login
                                        keychain on first use. The keychain may ask once whether
                                        this tool may use the item: choose Always Allow
      serve [--port N] [--poll]         run the local API in this process until Ctrl-C, over the
                                        same Runtime as `run`: for development, and for the Stream
                                        Deck plugin without the app. --poll also reads the monitor
                                        and the controller every pollingIntervalSeconds (reads only)
      streamdeck export [DIR] [--switchboardctl PATH]
                                        write a .command wrapper for every macro and every action
                                        without parameters, for the Stream Deck "Open" action, plus
                                        a README.txt. DIR defaults to
                                        ~/Library/Application Support/Switchboard/StreamDeck/
    """

// MARK: - Output

/// One line on stdout, written straight to the file descriptor so a pipe sees it at once.
private func emit(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

private func writeStderr(_ line: String) {
    FileHandle.standardError.write(Data(("switchboardctl: " + line + "\n").utf8))
}

// MARK: - Options

struct APIOptions {
    var json = false
    var port: Int?
    var poll = false
    var switchboardctl: String?
    var positional: [String] = []
}

/// Parses the flags a command allows; anything else starting with `--` is an error, so a typo never
/// silently does nothing.
func parseAPIOptions(_ args: ArraySlice<String>, allowing allowed: Set<String>, allowPortZero: Bool = false) throws -> APIOptions {
    var options = APIOptions()
    var iterator = args.makeIterator()
    while let arg = iterator.next() {
        guard arg.hasPrefix("--") else {
            options.positional.append(arg)
            continue
        }
        let flag = arg.firstIndex(of: "=").map { String(arg[..<$0]) } ?? arg
        guard allowed.contains(flag) else { throw CLIError("unknown option \(arg)\n\(usage)") }
        switch flag {
        case "--json":
            options.json = true
        case "--poll":
            options.poll = true
        case "--port":
            options.port = try parsePortOption(arg, &iterator, allowZero: allowPortZero)
        case "--switchboardctl":
            let value = arg.contains("=") ? String(arg[arg.index(after: arg.firstIndex(of: "=")!)...]) : iterator.next()
            guard let value, !value.isEmpty else { throw CLIError("--switchboardctl needs a path") }
            options.switchboardctl = value
        default:
            throw CLIError("unknown option \(arg)\n\(usage)")
        }
    }
    return options
}

/// `--port N` or `--port=N`.
func parsePortOption(_ arg: String, _ iterator: inout IndexingIterator<ArraySlice<String>>, allowZero: Bool = false) throws -> Int {
    let text: String
    if let equals = arg.firstIndex(of: "=") {
        text = String(arg[arg.index(after: equals)...])
    } else {
        guard let next = iterator.next() else { throw CLIError("--port needs a port number") }
        text = next
    }
    guard let port = Int(text), (allowZero ? 0 : 1)...65535 ~= port else {
        throw CLIError("--port needs a port number from \(allowZero ? 0 : 1) to 65535, got \"\(text)\"")
    }
    return port
}

private func rejectPositionals(_ options: APIOptions, for command: String) throws {
    if let extra = options.positional.first { throw CLIError("\(command) takes no argument, got \(extra)\n\(usage)") }
}

// MARK: - Finding the app

/// `SWITCHBOARD_TOKEN_FILE` (development and tests: a file instead of the keychain, so nothing
/// touches the login keychain), else the keychain item of `docs/DESIGN.md`.
func apiTokenStore(environment: [String: String] = ProcessInfo.processInfo.environment) -> any TokenStoring {
    if let path = environment["SWITCHBOARD_TOKEN_FILE"], !path.isEmpty {
        return FileTokenStore(url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }
    return KeychainTokenStore()
}

/// `--port`, else the `localAPIPort` setting.
func apiPort(_ explicit: Int?) async throws -> Int {
    if let explicit { return explicit }
    let directory = AppSupport.directory(environment: ProcessInfo.processInfo.environment)
    return try await SettingsStore(directory: directory).load().localAPIPort
}

func appNotRunning(port: Int) -> CLIError {
    CLIError(
        "Switchboard app is not running (no API at http://127.0.0.1:\(port)); start it, or use \"switchboardctl run\" which works offline",
        code: ExitCode.appNotRunning
    )
}

/// An authenticated client for a running app.
struct AppConnection {
    let client: LocalAPIClient
    let port: Int
}

/// How long `/health` gets to answer before the app counts as not running (docs/API.md: the CLI
/// prefers the API "when /health answers within 300 ms").
private let healthDeadline: TimeInterval = 0.3

/// True when a Switchboard API answers `/health` on the port. Another program on the port does
/// not count: the reply has to say it is Switchboard.
func appIsRunning(port: Int) async -> Bool {
    let probe = LocalAPIClient(baseURL: LocalAPIClient.baseURL(port: port), token: nil, timeout: healthDeadline)
    guard let health = try? await probe.health() else { return false }
    return health.ok && health.name == "Switchboard"
}

/// The connection to the running app, or nil when `/health` does not answer in time. Throws when
/// the app is there but this tool has no token to talk to it with.
func findApp(port explicit: Int?) async throws -> AppConnection? {
    let port = try await apiPort(explicit)
    guard await appIsRunning(port: port) else { return nil }
    guard let token = try apiTokenStore().load() else {
        throw CLIError(
            "the Switchboard app is running at http://127.0.0.1:\(port) but this tool has no API token for it; "
                + "`switchboardctl token` shows or creates the token this tool uses, and the app's settings pane the one it expects. "
                + "Use `switchboardctl run --local` to work without the app."
        )
    }
    return AppConnection(client: LocalAPIClient(baseURL: LocalAPIClient.baseURL(port: port), token: token), port: port)
}

/// Like `findApp`, for the commands that only make sense with the app: exit 8 when it is not there.
func requireApp(port explicit: Int?) async throws -> AppConnection {
    if let app = try await findApp(port: explicit) { return app }
    throw appNotRunning(port: try await apiPort(explicit))
}

/// What a failed API call means for the command line.
func apiFailure(_ error: LocalAPIError, port: Int, id: String? = nil) -> CLIError {
    switch error {
    case .unreachable:
        return appNotRunning(port: port)
    case .unauthorized:
        return CLIError(
            "the Switchboard app at http://127.0.0.1:\(port) rejected the API token (401). "
                + "`switchboardctl token` prints the token this tool uses; the app's settings pane shows the one it expects"
        )
    case .status(let code, _):
        if let body = error.errorBody {
            switch (code, body.error) {
            case (409, "busy"):
                return CLIError("another run is in progress (run \(body.runId ?? "unknown"))", code: ExitCode.busy)
            case (404, "unknown id"):
                return CLIError("unknown action or macro \"\(body.id ?? id ?? "")\"; see `switchboardctl actions` and `switchboardctl macros`")
            case (400, "missing parameter"):
                return CLIError("missing parameter \"\(body.parameter ?? "")\"")
            case (400, "invalid parameter"):
                return CLIError("invalid parameter \"\(body.parameter ?? "")\": \(body.reason ?? "")")
            default:
                break
            }
        }
        return CLIError("\(error)")
    case .invalidResponse:
        return CLIError("\(error)")
    }
}

// MARK: - run, actions, macros through the app

/// Runs through the app when it answers. Returns false, having done nothing, when it does not, so
/// the caller runs in process. Throws like `runInProcess`: the failed event is printed, then a
/// `CLIError` carries the exit code (3 unverified write, 6 controller, 7 busy, else 1).
func runThroughApp(_ request: RunRequest) async throws -> Bool {
    guard let app = try await findApp(port: request.port) else { return false }
    let parameters = runParameters(id: request.id, text: request.text)

    do {
        // Subscribe first, then start the run: the server subscribes to run events before it sends
        // the connect-time state, so once that arrives no event of the run can be missed.
        var events = app.client.events().makeAsyncIterator()
        guard let first = try await events.next(), case .state = first else {
            throw CLIError("the Switchboard app did not open its event stream")
        }

        let handle = try await app.client.run(id: request.id, parameters: parameters)

        while let event = try await events.next() {
            guard case .run(let run) = event, run.runId == handle.runId else { continue }
            printRunEvent(run, json: request.json)
            guard run.isTerminal else { continue }
            if run.status == .finished { return true }
            // The failed event is already on stdout; only the exit code is left to say.
            switch run.failureKind {
            case .unverifiedWrite: throw CLIError("", code: ExitCode.unverified)
            case .controllerUnreachable: throw CLIError("", code: ExitCode.controllerUnreachable)
            case .other, nil: throw CLIError("", code: ExitCode.error)
            }
        }
        throw CLIError("the Switchboard app closed the connection before the run ended")
    } catch let error as LocalAPIError {
        throw apiFailure(error, port: app.port, id: request.id)
    }
}

/// `GET /actions` from the app; nil when it is not running.
func actionsFromApp(port: Int?) async throws -> ActionList? {
    guard let app = try await findApp(port: port) else { return nil }
    do {
        return try await app.client.actions()
    } catch let error as LocalAPIError {
        throw apiFailure(error, port: app.port)
    }
}

/// `GET /macros` from the app; nil when it is not running.
func macrosFromApp(port: Int?) async throws -> MacroFile? {
    guard let app = try await findApp(port: port) else { return nil }
    do {
        return try await app.client.macros()
    } catch let error as LocalAPIError {
        throw apiFailure(error, port: app.port)
    }
}

// MARK: - state

func stateCommand(_ args: ArraySlice<String>) async throws {
    let options = try parseAPIOptions(args, allowing: ["--json", "--port"])
    try rejectPositionals(options, for: "state")
    let app = try await requireApp(port: options.port)
    let state: SwitchboardState
    do {
        state = try await app.client.state()
    } catch let error as LocalAPIError {
        throw apiFailure(error, port: app.port)
    }

    if options.json {
        let encoder = APIJSON.makeEncoder()
        encoder.outputFormatting.insert(.prettyPrinted)
        emit(String(decoding: try encoder.encode(state), as: UTF8.self))
        return
    }
    for line in state.summaryLines { emit(line) }
}

// MARK: - events

private enum EventsEnd {
    case interrupted
    case closed
    case failed(any Error)
}

func eventsCommand(_ args: ArraySlice<String>) async throws {
    let options = try parseAPIOptions(args, allowing: ["--json", "--port"])
    try rejectPositionals(options, for: "events")
    let app = try await requireApp(port: options.port)

    let client = app.client
    let json = options.json
    let end = await withTaskGroup(of: EventsEnd.self) { group in
        group.addTask {
            do {
                for try await event in client.events() {
                    if let line = event.line(json: json) { emit(line) }
                }
                return .closed
            } catch {
                return .failed(error)
            }
        }
        group.addTask {
            await waitForInterrupt()
            return .interrupted
        }
        let first = await group.next() ?? .interrupted
        group.cancelAll()
        return first
    }

    switch end {
    case .interrupted:
        return
    case .closed:
        throw CLIError("the Switchboard app closed the connection")
    case .failed(let error):
        if let error = error as? LocalAPIError { throw apiFailure(error, port: app.port) }
        throw error
    }
}

// MARK: - token

func tokenCommand(_ args: ArraySlice<String>) throws {
    let options = try parseAPIOptions(args, allowing: [])
    try rejectPositionals(options, for: "token")
    let (token, created) = try TokenStore.resolve(using: apiTokenStore())
    if created { writeStderr("created a new API token") }
    emit(token)
}

// MARK: - serve

func serveCommand(_ args: ArraySlice<String>) async throws {
    let options = try parseAPIOptions(args, allowing: ["--port", "--poll"], allowPortZero: true)
    try rejectPositionals(options, for: "serve")

    let environment = ProcessInfo.processInfo.environment
    let directory = AppSupport.directory(environment: environment)
    let settings = try await SettingsStore(directory: directory).load()
    let port = options.port ?? settings.localAPIPort
    guard let listenPort = UInt16(exactly: port) else {
        throw CLIError("localAPIPort \(port) is not a port number")
    }

    let (token, created) = try TokenStore.resolve(using: apiTokenStore(environment: environment))
    if created { writeStderr("created a new API token; `switchboardctl token` prints it") }

    let runtime = await Runtime.live(settings: settings, environment: environment, appSupport: directory)
    let server = LocalAPIServer(runtime: runtime, port: listenPort, token: token)
    do {
        try await server.start()
    } catch {
        throw CLIError(
            "cannot listen on 127.0.0.1:\(port): \(describeListenError(error)). "
                + "Is the Switchboard app (or another `switchboardctl serve`) already running? --port picks another port"
        )
    }

    if options.poll {
        await MainActor.run { runtime.refresher.start() }
    }

    let bound = await server.port
    emit("Switchboard \(SwitchboardVersion.current) API listening on http://127.0.0.1:\(bound)")
    emit("token: `switchboardctl token` (Authorization: Bearer <token>)")
    emit("controller: \(runtime.controllerURL?.absoluteString ?? "none (hdmi.* and usb.* actions will fail; see `switchboardctl settings`)")")
    emit(options.poll
        ? "polling the monitor and the controller every \(settings.text(for: .pollingIntervalSeconds)) s (reads only)"
        : "not polling: state stays unknown until a run or `--poll` (reads only) fills it")
    emit("press Ctrl-C to stop")

    await waitForInterrupt()
    if options.poll { await MainActor.run { runtime.refresher.stop() } }
    await server.stop()
}

// MARK: - streamdeck export

func streamdeckCommand(_ args: ArraySlice<String>) async throws {
    guard let sub = args.first else { throw CLIError("streamdeck needs a subcommand: export [DIR]\n\(usage)") }
    guard sub == "export" else { throw CLIError("unknown streamdeck command \(sub); use export\n\(usage)") }

    let options = try parseAPIOptions(args.dropFirst(), allowing: ["--switchboardctl"])
    guard options.positional.count <= 1 else {
        throw CLIError("streamdeck export takes at most one directory, got \(options.positional.joined(separator: " "))")
    }

    let environment = ProcessInfo.processInfo.environment
    let appSupport = AppSupport.directory(environment: environment)
    let directory = options.positional.first.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        ?? appSupport.appending(path: "StreamDeck", directoryHint: .isDirectory)

    guard let executable = options.switchboardctl ?? currentExecutablePath() else {
        throw CLIError("cannot tell where switchboardctl is; pass --switchboardctl /path/to/switchboardctl")
    }
    let path = executable.hasPrefix("/") ? executable : URL(fileURLWithPath: executable).standardizedFileURL.path(percentEncoded: false)

    let macros = try await MacroStore(directory: appSupport).load()
    let written: [URL]
    do {
        written = try StreamDeckWrappers.generate(
            into: directory,
            macros: macros,
            actions: ActionRegistry().descriptors,
            switchboardctlPath: path
        )
    } catch let error as StreamDeckWrappersError {
        throw CLIError("\(error)")
    }

    emit("wrote \(written.count) wrapper\(written.count == 1 ? "" : "s") and \(StreamDeckWrappers.readmeName) to \(directory.path(percentEncoded: false))")
    for url in written { emit("  " + url.lastPathComponent) }
    emit("each runs: \(path) run <id>")
    emit("Stream Deck: drag an \"Open\" action onto a key and choose one of these files. Run this command again after you add a macro or move switchboardctl.")
}

/// Where this executable lives, as an absolute path.
private func currentExecutablePath() -> String? {
    if let path = Bundle.main.executablePath { return URL(fileURLWithPath: path).standardizedFileURL.path(percentEncoded: false) }
    guard let first = CommandLine.arguments.first, first.contains("/") else { return nil }
    return URL(fileURLWithPath: first).standardizedFileURL.path(percentEncoded: false)
}
