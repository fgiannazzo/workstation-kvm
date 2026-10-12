import Foundation
import SwitchboardCore
import TinyHTTP

/// The outcome of one contract check.
public struct ContractCheck: Sendable, Equatable {
    public let name: String
    public let passed: Bool
    /// What was observed: a short summary when the check passed, the reason when it failed.
    public let detail: String

    public init(name: String, passed: Bool, detail: String) {
        self.name = name
        self.passed = passed
        self.detail = detail
    }
}

/// Runs the ESP32 contract (`docs/ESP32-CONTRACT.md`) against a controller. The same test runs
/// against `MockESP32` in `swift test` and against real firmware through
/// `switchboardctl controller contract-test --url http://<esp32>`.
///
/// Each check stands alone: it reads what it needs, changes at most one thing, and puts it back
/// before it reports. A failing check never stops the others. Against real hardware the checks
/// do move things: `lg4k` is selected away and back with `select` (two button pulses), and the
/// USB switch goes to another port and back. The `resync` and `/events` checks only touch the
/// assumed state of `dualup`.
public struct ContractTest: Sendable {
    public let baseURL: URL

    /// How long a request, an event or the first byte of the event stream may take.
    static let deadline: Duration = .seconds(3)

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Runs the six checks in order and returns one result for each.
    public func run() async -> [ContractCheck] {
        let wire = Wire(baseURL: baseURL)
        defer { wire.invalidate() }

        let checks: [(name: String, body: @Sendable () async throws -> String)] = [
            ("GET /state returns the state object", { try await Self.checkState(wire) }),
            ("POST /hdmi/dualup/resync sets the assumed input", { try await Self.checkHDMI(wire, display: .dualup, action: "resync") }),
            ("POST /hdmi/lg4k/select changes the input", { try await Self.checkHDMI(wire, display: .lg4k, action: "select") }),
            ("POST /usb/select changes the port", { try await Self.checkUSB(wire) }),
            ("errors: unknown display is 404, invalid input is 400", { try await Self.checkValidation(wire) }),
            ("GET /events sends the state on connect and on change", { try await Self.checkEvents(wire) }),
        ]

        var results: [ContractCheck] = []
        for (name, body) in checks {
            do {
                results.append(ContractCheck(name: name, passed: true, detail: try await body()))
            } catch let failure as Failure {
                results.append(ContractCheck(name: name, passed: false, detail: failure.message))
            } catch {
                results.append(ContractCheck(name: name, passed: false, detail: "\(error)"))
            }
        }
        return results
    }

    // MARK: Checks

    private static func checkState(_ wire: Wire) async throws -> String {
        let reply = try await wire.request("GET", "state")
        try reply.expectStatus(200, "GET /state")

        // The raw keys first, so a controller that renames one is reported by name.
        guard let object = try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any] else {
            throw Failure("GET /state: body is not a JSON object: \(reply.preview)")
        }
        for key in ["hdmi", "usb", "uptime"] where object[key] == nil {
            throw Failure("GET /state: missing key \"\(key)\" in \(reply.preview)")
        }
        let state = try reply.decodeState("GET /state")
        let missing = DisplayID.allCases.filter { state.hdmi[$0] == nil }
        guard missing.isEmpty else {
            throw Failure("GET /state: hdmi has no entry for \(missing.map(\.rawValue).joined(separator: ", "))")
        }
        for (display, input) in state.hdmi.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where !(1...2).contains(input) {
            throw Failure("GET /state: hdmi.\(display.rawValue) is \(input), expected 1 or 2")
        }
        guard (1...4).contains(state.usb.port) else {
            throw Failure("GET /state: usb.port is \(state.usb.port), expected 1...4")
        }
        guard !state.usb.source.isEmpty else {
            throw Failure("GET /state: usb.source is empty")
        }
        guard state.uptime >= 0 else {
            throw Failure("GET /state: uptime is \(state.uptime), expected >= 0")
        }
        return "\(describe(state))"
    }

    /// `action` is `resync` (no pulse) or `select` (pulses the real switch).
    private static func checkHDMI(_ wire: Wire, display: DisplayID, action: String) async throws -> String {
        let before = try await wire.state("before")
        guard let original = before.hdmi[display] else {
            throw Failure("GET /state: hdmi has no entry for \(display.rawValue)")
        }
        let target = original == 1 ? 2 : 1
        let path = "hdmi/\(display.rawValue)/\(action)"

        return try await restoring({
            try await wire.put(display: display, input: original, action: action)
        }, {
            let reply = try await wire.request("POST", path, json: ["input": target])
            try reply.expectStatus(200, "POST /\(path)")
            let answered = try reply.decodeState("POST /\(path)")
            guard answered.hdmi[display] == target else {
                throw Failure("POST /\(path) {\"input\":\(target)}: reply has hdmi.\(display.rawValue) = \(answered.hdmi[display].map(String.init) ?? "nil"), expected \(target)")
            }
            let after = try await wire.state("after")
            guard after.hdmi[display] == target else {
                throw Failure("GET /state after \(action): hdmi.\(display.rawValue) = \(after.hdmi[display].map(String.init) ?? "nil"), expected \(target)")
            }
            for other in DisplayID.allCases where other != display && after.hdmi[other] != before.hdmi[other] {
                throw Failure("\(action) on \(display.rawValue) also changed hdmi.\(other.rawValue)")
            }
            guard after.usb.port == before.usb.port else {
                throw Failure("\(action) on \(display.rawValue) also changed usb.port")
            }
            return "\(display.rawValue) \(original) -> \(target) -> \(original)"
        })
    }

    private static func checkUSB(_ wire: Wire) async throws -> String {
        let before = try await wire.state("before")
        let original = before.usb.port
        let target = original % 4 + 1

        return try await restoring({
            try await wire.put(usbPort: original)
        }, {
            let reply = try await wire.request("POST", "usb/select", json: ["port": target])
            try reply.expectStatus(200, "POST /usb/select")
            let answered = try reply.decodeState("POST /usb/select")
            guard answered.usb.port == target else {
                throw Failure("POST /usb/select {\"port\":\(target)}: reply has usb.port = \(answered.usb.port), expected \(target)")
            }
            let after = try await wire.state("after")
            guard after.usb.port == target else {
                throw Failure("GET /state after usb/select: usb.port = \(after.usb.port), expected \(target)")
            }
            guard after.hdmi == before.hdmi else {
                throw Failure("usb/select also changed hdmi")
            }
            return "usb port \(original) -> \(target) -> \(original)"
        })
    }

    private static func checkValidation(_ wire: Wire) async throws -> String {
        let before = try await wire.state("before")

        return try await restoring({
            try await wire.restore(to: before)
        }, {
            let cases: [(label: String, method: String, path: String, body: [String: Int], expected: Int)] = [
                ("select on an unknown display", "POST", "hdmi/nosuchdisplay/select", ["input": 1], 404),
                ("resync on an unknown display", "POST", "hdmi/nosuchdisplay/resync", ["input": 1], 404),
                ("select with input 3", "POST", "hdmi/dualup/select", ["input": 3], 400),
                ("select with input 0", "POST", "hdmi/dualup/select", ["input": 0], 400),
                ("resync with input 3", "POST", "hdmi/dualup/resync", ["input": 3], 400),
                ("usb/select with port 5", "POST", "usb/select", ["port": 5], 400),
                ("usb/select with port 0", "POST", "usb/select", ["port": 0], 400),
            ]
            for item in cases {
                let reply = try await wire.request(item.method, item.path, json: item.body)
                guard reply.status == item.expected else {
                    throw Failure("\(item.label): expected \(item.expected), got \(reply.status) \(reply.preview)")
                }
            }
            let after = try await wire.state("after")
            guard after.hdmi == before.hdmi, after.usb == before.usb else {
                throw Failure("a rejected request changed the state: \(describe(before)) -> \(describe(after))")
            }
            return "\(cases.count) rejected requests, state untouched"
        })
    }

    private static func checkEvents(_ wire: Wire) async throws -> String {
        let before = try await wire.state("before")
        guard let original = before.hdmi[.dualup] else {
            throw Failure("GET /state: hdmi has no entry for dualup")
        }
        let target = original == 1 ? 2 : 1

        let inbox = EventInbox()
        let reader = Task { await wire.readEvents(into: inbox) }
        defer { reader.cancel() }

        let clock = ContinuousClock()
        let connected = clock.now
        guard let head = await inbox.waitForHead(within: deadline) else {
            throw Failure("GET /events: no response within 3 s of connecting\(await inbox.failureSuffix)")
        }
        guard head.status == 200 else {
            throw Failure("GET /events: expected 200, got \(head.status)")
        }
        guard head.contentType.lowercased().hasPrefix("text/event-stream") else {
            throw Failure("GET /events: Content-Type is \"\(head.contentType)\", expected text/event-stream")
        }
        guard await inbox.wait(from: 0, within: deadline, where: { _ in true }) != nil else {
            throw Failure("GET /events: no state event within 3 s of connecting\(await inbox.failureSuffix)")
        }
        let firstAfter = clock.now - connected
        let seen = await inbox.count

        return try await restoring({
            try await wire.put(display: .dualup, input: original, action: "resync")
        }, {
            let changed = clock.now
            let reply = try await wire.request("POST", "hdmi/dualup/resync", json: ["input": target])
            try reply.expectStatus(200, "POST /hdmi/dualup/resync")
            guard await inbox.wait(from: seen, within: deadline, where: { $0.hdmi[.dualup] == target }) != nil else {
                throw Failure("GET /events: no event with hdmi.dualup = \(target) within 3 s of a change\(await inbox.failureSuffix)")
            }
            return "state on connect within \(milliseconds(firstAfter)) ms, change event within \(milliseconds(clock.now - changed)) ms"
        })
    }

    // MARK: Helpers

    /// Runs `body`, then always `restore`. A restore that fails fails the check even when the
    /// body passed, because the controller is now left in a state the user did not choose.
    private static func restoring(
        _ restore: @Sendable () async throws -> Void,
        _ body: @Sendable () async throws -> String
    ) async throws -> String {
        let outcome: Result<String, any Error>
        do {
            outcome = .success(try await body())
        } catch {
            outcome = .failure(error)
        }
        do {
            try await restore()
        } catch {
            let restoreMessage = "could not restore the previous state: \(message(error))"
            if case .failure(let failure) = outcome {
                throw Failure("\(message(failure)); \(restoreMessage)")
            }
            throw Failure(restoreMessage)
        }
        return try outcome.get()
    }

    fileprivate static func message(_ error: any Error) -> String {
        (error as? Failure)?.message ?? "\(error)"
    }

    private static func describe(_ state: ControllerState) -> String {
        let hdmi = DisplayID.allCases.map { "\($0.rawValue)=\(state.hdmi[$0].map(String.init) ?? "-")" }.joined(separator: " ")
        return "\(hdmi) usb=\(state.usb.port) (\(state.usb.source)) uptime=\(state.uptime)s"
    }

    /// Whole milliseconds, at least 1 (the checks poll, so "0 ms" would overstate the precision).
    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return max(1, Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000))
    }

    struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}

// MARK: - HTTP

private struct Reply: Sendable {
    let status: Int
    let body: Data

    var preview: String {
        let text = String(decoding: body.prefix(120), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "(empty body)" : text
    }

    func expectStatus(_ expected: Int, _ what: String) throws {
        guard status == expected else {
            throw ContractTest.Failure("\(what): expected \(expected), got \(status) \(preview)")
        }
    }

    func decodeState(_ what: String) throws -> ControllerState {
        do {
            return try JSONDecoder().decode(ControllerState.self, from: body)
        } catch {
            throw ContractTest.Failure("\(what): reply is not a state object (\(error.localizedDescription)): \(preview)")
        }
    }
}

/// Raw HTTP for the contract test. It does not use `ESP32Client`: the point is to check the wire,
/// including requests the typed client cannot express (an unknown display).
private final class Wire: Sendable {
    let baseURL: URL
    let session: URLSession

    init(baseURL: URL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    func request(_ method: String, _ path: String, json: [String: Int]? = nil) async throws -> Reply {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 5
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ContractTest.Failure("\(method) /\(path): not an HTTP response")
            }
            return Reply(status: http.statusCode, body: data)
        } catch let failure as ContractTest.Failure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ContractTest.Failure("\(method) /\(path): \(ESP32Client.map(error, url: url))")
        }
    }

    func state(_ when: String) async throws -> ControllerState {
        let reply = try await request("GET", "state")
        try reply.expectStatus(200, "GET /state (\(when))")
        return try reply.decodeState("GET /state (\(when))")
    }

    /// Sets one display's input and checks it took.
    func put(display: DisplayID, input: Int, action: String) async throws {
        let reply = try await request("POST", "hdmi/\(display.rawValue)/\(action)", json: ["input": input])
        try reply.expectStatus(200, "POST /hdmi/\(display.rawValue)/\(action)")
        let state = try await self.state("restore")
        guard state.hdmi[display] == input else {
            throw ContractTest.Failure("hdmi.\(display.rawValue) is \(state.hdmi[display].map(String.init) ?? "nil") after putting it back to \(input)")
        }
    }

    func put(usbPort: Int) async throws {
        let reply = try await request("POST", "usb/select", json: ["port": usbPort])
        try reply.expectStatus(200, "POST /usb/select")
        let state = try await self.state("restore")
        guard state.usb.port == usbPort else {
            throw ContractTest.Failure("usb.port is \(state.usb.port) after putting it back to \(usbPort)")
        }
    }

    /// Puts back whatever differs from `original`: assumed HDMI inputs with `resync` (no pulse),
    /// the USB port with `usb/select`.
    func restore(to original: ControllerState) async throws {
        let current = try await state("restore")
        for display in DisplayID.allCases {
            if let input = original.hdmi[display], current.hdmi[display] != input {
                try await put(display: display, input: input, action: "resync")
            }
        }
        if current.usb.port != original.usb.port {
            try await put(usbPort: original.usb.port)
        }
    }

    /// Connects to `/events` and records the response head and every state into `inbox` until
    /// the task is cancelled or the connection ends.
    func readEvents(into inbox: EventInbox) async {
        var request = URLRequest(url: baseURL.appending(path: "events"))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                await inbox.fail("not an HTTP response")
                return
            }
            await inbox.setHead(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "")
            for try await event in SSEParser.events(from: bytes) {
                if let state = try? JSONDecoder().decode(ControllerState.self, from: Data(event.data.utf8)) {
                    await inbox.append(state)
                }
            }
            await inbox.fail("the stream ended")
        } catch is CancellationError {
            return
        } catch {
            await inbox.fail("\(ESP32Client.map(error, url: request.url ?? URL(fileURLWithPath: "/")))")
        }
    }
}

/// What the event reader has seen so far; the check polls it with deadlines. (Not an
/// `AsyncStream`: cancelling a wait on one would end it for good.)
private actor EventInbox {
    struct Head: Sendable {
        let status: Int
        let contentType: String
    }

    private var head: Head?
    private var states: [ControllerState] = []
    private var failure: String?

    var count: Int { states.count }

    /// `"; <reason>"` when the reader stopped with an error, else empty.
    var failureSuffix: String { failure.map { " (\($0))" } ?? "" }

    func setHead(status: Int, contentType: String) { head = Head(status: status, contentType: contentType) }
    func append(_ state: ControllerState) { states.append(state) }
    func fail(_ reason: String) { if failure == nil { failure = reason } }

    func waitForHead(within limit: Duration) async -> Head? {
        let clock = ContinuousClock()
        let end = clock.now + limit
        while clock.now < end {
            if let head { return head }
            if failure != nil { return nil }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return head
    }

    /// The first state from index `start` on that satisfies `predicate`, within `limit`.
    func wait(from start: Int, within limit: Duration, where predicate: @Sendable (ControllerState) -> Bool) async -> ControllerState? {
        let clock = ContinuousClock()
        let end = clock.now + limit
        var index = start
        while true {
            while index < states.count {
                if predicate(states[index]) { return states[index] }
                index += 1
            }
            if failure != nil || clock.now >= end { return nil }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
