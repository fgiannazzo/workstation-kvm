import ESP32Kit
import Foundation
import Network
import SwitchboardCore

// `switchboardctl controller ...`: the ESP32 controller (docs/ESP32-CONTRACT.md). Same split as
// main.swift: logic lives in ESP32Kit, this file parses arguments and formats output.
// Exit codes: 0 ok, 1 error, 5 controller unreachable (set in main.swift's error handling).

let controllerHelp = """
      controller state [OPTIONS]        read the ESP32 controller's state
      controller hdmi <dualup|lg4k|samsung> <1|2> [--resync] [OPTIONS]
                                        select an HDMI input (pulses the display's OREI switch);
                                        with --resync only correct the assumed input, no pulse
      controller usb <1-4> [OPTIONS]    switch the USB switch to a port
      controller events [OPTIONS]       print every state the controller reports, one line each,
                                        until Ctrl-C
      controller discover [--timeout S] [--json]
                                        list controllers advertising _switchboard._tcp (mDNS)
      controller contract-test [OPTIONS]
                                        run the ESP32 contract test; exit 0 when every check
                                        passes. On a real controller it moves lg4k and the USB
                                        port away and back
      controller mock [--port 48700] [--host 127.0.0.1] [--advertise]
                                        run a mock controller until Ctrl-C and print each request
                                        (--advertise publishes _switchboard._tcp and, unless
                                        --host is given, binds 0.0.0.0 so the LAN can reach it)
        OPTIONS (controller state|hdmi|usb|events|contract-test):
          --url http://host:port        the controller (default: env SWITCHBOARD_CONTROLLER_URL)
          --discover [--timeout S]      use the first mDNS result instead (S seconds, default 3)
          --json                        print JSON instead of text
    """

/// Everything the `controller` subcommands accept. Each subcommand lists the flags it allows;
/// anything else is an error, so a typo never silently does nothing.
struct ControllerOptions {
    var url: String?
    var discover = false
    var timeout: Double = 3
    var json = false
    var resync = false
    var port: UInt16 = 48700
    var host: String?
    var advertise = false
    var positional: [String] = []
}

func parseControllerOptions(_ args: ArraySlice<String>, allowing allowed: Set<String>) throws -> ControllerOptions {
    var options = ControllerOptions()
    var iterator = args.makeIterator()

    func value(for flag: String, inline: String?, _ iterator: inout IndexingIterator<ArraySlice<String>>) throws -> String {
        if let inline {
            guard !inline.isEmpty else { throw CLIError("\(flag) needs a value") }
            return inline
        }
        guard let next = iterator.next(), !next.isEmpty else { throw CLIError("\(flag) needs a value") }
        return next
    }

    while let arg = iterator.next() {
        guard arg.hasPrefix("--") else {
            options.positional.append(arg)
            continue
        }
        let flag: String
        let inline: String?
        if let equals = arg.firstIndex(of: "=") {
            flag = String(arg[..<equals])
            inline = String(arg[arg.index(after: equals)...])
        } else {
            flag = arg
            inline = nil
        }
        guard allowed.contains(flag) else { throw CLIError("unknown option \(arg)\n\(usage)") }

        switch flag {
        case "--json": options.json = true
        case "--discover": options.discover = true
        case "--resync": options.resync = true
        case "--advertise": options.advertise = true
        case "--url":
            options.url = try value(for: flag, inline: inline, &iterator)
        case "--host":
            options.host = try value(for: flag, inline: inline, &iterator)
        case "--timeout":
            let text = try value(for: flag, inline: inline, &iterator)
            guard let seconds = Double(text), seconds > 0, seconds <= 60 else {
                throw CLIError("--timeout needs a number of seconds between 0 and 60, got \(text)")
            }
            options.timeout = seconds
        case "--port":
            let text = try value(for: flag, inline: inline, &iterator)
            guard let port = UInt16(text) else { throw CLIError("--port needs a port number (0-65535), got \(text)") }
            options.port = port
        default:
            throw CLIError("unknown option \(arg)\n\(usage)")
        }
    }
    return options
}

private let connectionFlags: Set<String> = ["--url", "--discover", "--timeout", "--json"]

func controllerCommand(_ args: ArraySlice<String>) async throws {
    guard let sub = args.first else {
        throw CLIError("controller needs a subcommand\n\(usage)")
    }
    let rest = args.dropFirst()

    switch sub {
    case "state":
        let options = try parseControllerOptions(rest, allowing: connectionFlags)
        try rejectPositionals(options, for: "controller state")
        let client = try await controllerClient(options)
        printControllerState(try await client.state(), json: options.json)

    case "hdmi":
        let options = try parseControllerOptions(rest, allowing: connectionFlags.union(["--resync"]))
        guard options.positional.count == 2 else {
            throw CLIError("usage: controller hdmi <dualup|lg4k|samsung> <1|2> [--resync]")
        }
        guard let display = DisplayID(rawValue: options.positional[0]) else {
            throw CLIError("unknown display \(options.positional[0]); use one of \(DisplayID.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard let input = Int(options.positional[1]), (1...2).contains(input) else {
            throw CLIError("input must be 1 or 2, got \(options.positional[1])")
        }
        let client = try await controllerClient(options)
        let state = options.resync
            ? try await client.resyncHDMI(display, input: input)
            : try await client.selectHDMI(display, input: input)
        printControllerState(state, json: options.json)

    case "usb":
        let options = try parseControllerOptions(rest, allowing: connectionFlags)
        guard options.positional.count == 1 else { throw CLIError("usage: controller usb <1-4>") }
        guard let port = Int(options.positional[0]), (1...4).contains(port) else {
            throw CLIError("USB port must be 1 to 4, got \(options.positional[0])")
        }
        let client = try await controllerClient(options)
        printControllerState(try await client.selectUSB(port: port), json: options.json)

    case "events":
        let options = try parseControllerOptions(rest, allowing: connectionFlags)
        try rejectPositionals(options, for: "controller events")
        try await controllerEvents(options)

    case "discover":
        let options = try parseControllerOptions(rest, allowing: ["--timeout", "--json"])
        try rejectPositionals(options, for: "controller discover")
        await controllerDiscover(options)

    case "contract-test":
        let options = try parseControllerOptions(rest, allowing: connectionFlags)
        try rejectPositionals(options, for: "controller contract-test")
        try await controllerContractTest(options)

    case "mock":
        let options = try parseControllerOptions(rest, allowing: ["--port", "--host", "--advertise"])
        try rejectPositionals(options, for: "controller mock")
        try await controllerMock(options)

    default:
        throw CLIError("unknown controller command \(sub)\n\(usage)")
    }
}

private func rejectPositionals(_ options: ControllerOptions, for command: String) throws {
    if let extra = options.positional.first { throw CLIError("\(command) takes no argument, got \(extra)") }
}

// MARK: - Finding the controller

/// `--url` wins, then `--discover`, then `SWITCHBOARD_CONTROLLER_URL`.
func controllerBaseURL(_ options: ControllerOptions) async throws -> URL {
    if options.url != nil, options.discover {
        throw CLIError("--url and --discover are alternatives; pass one")
    }
    if let raw = options.url {
        return try parseControllerURL(raw, source: "--url")
    }
    if options.discover {
        guard let found = await ESP32Discovery.first(timeout: .seconds(options.timeout)) else {
            throw CLIError(
                "no controller found on _switchboard._tcp within \(formatSeconds(options.timeout)) s; pass --url http://host:port",
                code: ExitCode.controllerUnreachable
            )
        }
        writeStderr("using \(found.name) at \(found.url.absoluteString)")
        return found.url
    }
    if let raw = ProcessInfo.processInfo.environment["SWITCHBOARD_CONTROLLER_URL"], !raw.isEmpty {
        return try parseControllerURL(raw, source: "SWITCHBOARD_CONTROLLER_URL")
    }
    throw CLIError("no controller address: pass --url http://host:port, use --discover, or set SWITCHBOARD_CONTROLLER_URL")
}

func parseControllerURL(_ raw: String, source: String) throws -> URL {
    // "192.168.1.50:80" without a scheme is what people type; accept it as http.
    let text = raw.contains("://") ? raw : "http://" + raw
    guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
          let host = url.host(), !host.isEmpty
    else {
        throw CLIError("\(source): \"\(raw)\" is not a controller address; expected http://host:port")
    }
    return url
}

func controllerClient(_ options: ControllerOptions) async throws -> ESP32Client {
    ESP32Client(baseURL: try await controllerBaseURL(options))
}

// MARK: - Output

private func jsonText<T: Encodable>(_ value: T, pretty: Bool) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

/// One line on stdout, written straight to the file descriptor so a pipe sees it at once and an
/// interrupt cannot lose it in a buffer.
private func emit(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

private func writeStderr(_ line: String) {
    FileHandle.standardError.write(Data(("switchboardctl: " + line + "\n").utf8))
}

private func formatSeconds(_ seconds: Double) -> String {
    seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
}

/// `dualup=1 lg4k=1 samsung=1 usb=1 (aten) uptime=123s`
private func stateLine(_ state: ControllerState) -> String {
    let hdmi = DisplayID.allCases.map { "\($0.rawValue)=\(state.hdmi[$0].map(String.init) ?? "?")" }.joined(separator: " ")
    return "\(hdmi) usb=\(state.usb.port) (\(state.usb.source)) uptime=\(state.uptime)s"
}

func printControllerState(_ state: ControllerState, json: Bool) {
    if json {
        if let text = try? jsonText(state, pretty: true) { emit(text) }
        return
    }
    let hdmi = DisplayID.allCases.map { "\($0.rawValue) \(state.hdmi[$0].map(String.init) ?? "unknown")" }.joined(separator: "  ")
    emit("hdmi: \(hdmi)")
    emit("usb: port \(state.usb.port) (\(state.usb.source))")
    emit("uptime: \(state.uptime) s")
}

// MARK: - Subcommands

private func controllerEvents(_ options: ControllerOptions) async throws {
    let client = try await controllerClient(options)
    // Fail fast with the real reason; the stream itself reconnects silently forever.
    _ = try await client.state()

    let json = options.json
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for await state in client.events() {
                if json {
                    if let text = try? jsonText(state, pretty: false) { emit(text) }
                } else {
                    emit(stateLine(state))
                }
            }
        }
        group.addTask { await waitForInterrupt() }
        await group.next()
        group.cancelAll()
    }
}

private func controllerDiscover(_ options: ControllerOptions) async {
    let found = await ESP32Discovery.browse(timeout: .seconds(options.timeout))
    if options.json {
        struct Entry: Encodable {
            let name: String
            let host: String
            let port: Int
            let url: String
        }
        let entries = found.map { Entry(name: $0.name, host: $0.host, port: Int($0.port), url: $0.url.absoluteString) }
        if let text = try? jsonText(entries, pretty: true) { emit(text) }
        return
    }
    if found.isEmpty {
        emit("no controllers found on _switchboard._tcp within \(formatSeconds(options.timeout)) s")
        return
    }
    for controller in found {
        emit("\(controller.name)  \(controller.url.absoluteString)")
    }
}

private func controllerContractTest(_ options: ControllerOptions) async throws {
    let url = try await controllerBaseURL(options)

    // An unreachable controller is exit 5, not six failed checks.
    do {
        _ = try await ESP32Client(baseURL: url).state()
    } catch let error as ControllerError {
        switch error {
        case .unreachable, .timeout: throw error
        case .httpStatus, .invalidResponse: break   // the contract test reports these properly
        }
    }

    if !options.json {
        writeStderr("running the contract test against \(url.absoluteString); a real controller will switch lg4k and the USB port away and back")
    }
    let results = await ContractTest(baseURL: url).run()

    if options.json {
        struct Entry: Encodable {
            let name: String
            let passed: Bool
            let detail: String
        }
        let entries = results.map { Entry(name: $0.name, passed: $0.passed, detail: $0.detail) }
        emit(try jsonText(entries, pretty: true))
    } else {
        for check in results {
            emit("\(check.passed ? "PASS" : "FAIL")  \(check.name): \(check.detail)")
        }
        emit("\(results.filter(\.passed).count)/\(results.count) checks passed")
    }
    if results.contains(where: { !$0.passed }) {
        throw CLIError("contract test failed")
    }
}

private func controllerMock(_ options: ControllerOptions) async throws {
    // A mock that is advertised on the LAN has to be reachable from the LAN.
    let host = options.host ?? (options.advertise ? "0.0.0.0" : "127.0.0.1")
    let mock = MockESP32(
        host: host,
        port: options.port,
        bonjour: options.advertise,
        onRequest: { entry in
            let time = entry.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
            let body = entry.body.isEmpty ? "" : " \(entry.body)"
            emit("\(time)  \(entry.method) \(entry.path)\(body) -> \(entry.status)")
        }
    )
    do {
        try await mock.start()
    } catch {
        throw CLIError("cannot listen on \(host):\(options.port): \(describeListenError(error))")
    }

    let port = await mock.port
    let reachable = host == "0.0.0.0" || host == "::" ? ProcessInfo.processInfo.hostName : host
    emit("mock ESP32 listening on http://\(reachable):\(port)")
    if options.advertise {
        emit("advertising \(ESP32Discovery.serviceType) as \"Switchboard Mock\"")
    }
    emit("press Ctrl-C to stop")

    await waitForInterrupt()
    await mock.stop()
}

private func describeListenError(_ error: any Error) -> String {
    if let network = error as? NWError, case .posix(let code) = network {
        return String(cString: strerror(code.rawValue))
    }
    return "\(error)"
}

/// Returns when the process receives SIGINT or SIGTERM, or when the calling task is cancelled.
private func waitForInterrupt() async {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let sources = [SIGINT, SIGTERM].map { number -> any DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { continuation.yield() }
        source.resume()
        return source
    }
    for await _ in stream { break }
    for source in sources { source.cancel() }
    continuation.finish()
}
