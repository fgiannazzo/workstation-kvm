import Actions
import DDCKit
import Devices
import ESP32Kit
import Foundation
import LocalAPI
import os
import StateStore
import SwitchboardCore
import Testing
import TinyHTTP

// MARK: - Time

let instant: Sleeper = { _ in }

struct TimeoutError: Error {}

/// Runs `body` with a deadline so a hang fails the test instead of stalling the suite. The timer
/// only matters when something is wrong.
func withTimeout<T: Sendable>(_ limit: Duration = .seconds(10), _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw TimeoutError() }
        return first
    }
}

/// Polls `condition` until it holds; fails the test after `limit`.
func eventually(
    _ limit: Duration = .seconds(5),
    _ message: String = "condition never held",
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @escaping @Sendable () async -> Bool
) async {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
}

/// A fresh directory path that is removed afterwards (not created).
func withTempDirectory<T>(actor: isolated (any Actor)? = #isolation, _ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory.appending(path: "switchboard-localapi-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

// MARK: - A controller

/// Holds callers back until `release()`.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// A `ControllerClient` that keeps its state in memory and records every call.
actor FakeController: ControllerClient {
    private var current: ControllerState
    private(set) var calls: [String] = []
    private let eventStream: AsyncStream<ControllerState>

    init(state: ControllerState = FakeController.initialState) {
        self.current = state
        (eventStream, _) = AsyncStream<ControllerState>.makeStream()
    }

    static let initialState = ControllerState(
        hdmi: [.dualup: 1, .lg4k: 1, .samsung: 1],
        usb: .init(port: 1, source: "aten"),
        uptime: 10
    )

    func state() async throws -> ControllerState {
        calls.append("state")
        return current
    }

    func selectHDMI(_ display: DisplayID, input: Int) async throws -> ControllerState {
        calls.append("selectHDMI(\(display.rawValue), \(input))")
        current.hdmi[display] = input
        return current
    }

    func resyncHDMI(_ display: DisplayID, input: Int) async throws -> ControllerState {
        calls.append("resyncHDMI(\(display.rawValue), \(input))")
        current.hdmi[display] = input
        return current
    }

    func selectUSB(port: Int) async throws -> ControllerState {
        calls.append("selectUSB(\(port))")
        current.usb.port = port
        return current
    }

    nonisolated func events() -> AsyncStream<ControllerState> { eventStream }
}

// MARK: - A wired-up API

/// 2026-10-11T20:15:03.120Z, the clock of every state in these tests.
let fixedNow = Date(timeIntervalSince1970: 1_791_749_703.12)

/// One running `LocalAPIServer` over a `Runtime` with fakes, and the pieces the tests poke at.
@MainActor
struct Harness {
    let runtime: Runtime
    let controller: FakeController
    let server: LocalAPIServer
    let token: String
    let baseURL: URL
    /// Closed (released) by default; `delay` runs wait on it when `holdDelays` was set.
    let delayGate: Gate
    let session: URLSession

    var store: StateStore { runtime.store }

    func client(token: String? = nil) -> LocalAPIClient {
        LocalAPIClient(baseURL: baseURL, token: token ?? self.token, timeout: 5, session: session)
    }

    // MARK: Raw HTTP

    struct Reply {
        let status: Int
        let body: Data
        let headers: [String: String]
        var text: String { String(decoding: body, as: UTF8.self) }
        func json() throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
    }

    enum Auth {
        /// The harness's own token.
        case valid
        case none
        case bearer(String)
    }

    func request(
        _ method: String,
        _ path: String,
        auth: Auth = .valid,
        body: String? = nil,
        headers: [String: String] = [:]
    ) async throws -> Reply {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + path)!)
        request.httpMethod = method
        switch auth {
        case .valid: request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .none: break
        case .bearer(let other): request.setValue("Bearer \(other)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body { request.httpBody = Data(body.utf8) }
        let (data, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        var received: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { received[key.lowercased()] = value }
        }
        return Reply(status: http.statusCode, body: data, headers: received)
    }

    /// Without any `Authorization` header.
    func anonymous(_ method: String, _ path: String, body: String? = nil) async throws -> Reply {
        try await request(method, path, auth: .none, body: body)
    }
}

/// A `Runtime` over fakes: a monitor whose cable always reads PBP off, and an in-memory controller.
@MainActor
func makeFakeRuntime(
    settings: Settings = Settings(),
    directory: URL,
    controller: FakeController = FakeController(),
    gate: Gate? = nil
) -> Runtime {
    let cable = FakeDDC(name: "fake video cable", reads: [0xD7: [1], 0xF5: [1]])
    let bridge = FakeDDC(name: "fake USB bridge", supportsRead: false)
    let dualUp = LGDualUp(videoCable: cable, usbBridge: bridge, sleep: instant)
    let sleeper: Sleeper
    if let gate {
        sleeper = { _ in await gate.wait() }
    } else {
        sleeper = instant
    }
    return Runtime(
        settings: settings,
        controllerURL: URL(string: "http://fake:1"),
        dualUp: dualUp,
        controller: controller,
        appSupport: directory,
        notify: { _ in },
        sleep: sleeper,
        store: StateStore(now: { fixedNow })
    )
}

/// Runs `body` against a started server on a free loopback port, then stops everything.
///
/// - Parameters:
///   - keepalive: the `/events` keepalive interval.
///   - holdDelays: `delay` runs block until `harness.delayGate` is released.
@MainActor
func withAPI<T>(
    token: String = "test-token-\(UUID().uuidString)",
    version: String = SwitchboardVersion.current,
    keepalive: Duration = .seconds(15),
    holdDelays: Bool = false,
    _ body: (Harness) async throws -> T
) async throws -> T {
    let directory = FileManager.default.temporaryDirectory.appending(path: "switchboard-localapi-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = FakeController()
    let gate = Gate()
    let runtime = makeFakeRuntime(directory: directory, controller: controller, gate: holdDelays ? gate : nil)

    let server = LocalAPIServer(runtime: runtime, port: 0, token: token, version: version, keepaliveInterval: keepalive)
    try await server.start()
    let port = await server.port

    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.timeoutIntervalForRequest = 10
    let harness = Harness(
        runtime: runtime,
        controller: controller,
        server: server,
        token: token,
        baseURL: URL(string: "http://127.0.0.1:\(port)")!,
        delayGate: gate,
        session: URLSession(configuration: configuration)
    )

    do {
        let result = try await body(harness)
        await gate.release()
        await server.stop()
        return result
    } catch {
        await gate.release()
        await server.stop()
        throw error
    }
}

// MARK: - An event stream

/// Subscribes to `/events` and keeps everything that arrives, so a test can wait for what it
/// expects. `lines` is the raw text, comments included.
final class EventCollector: Sendable {
    private struct Captured {
        var events: [SSEEvent] = []
        var rawLines: [String] = []
        var status: Int?
        var finished = false
    }

    private let captured = OSAllocatedUnfairLock(initialState: Captured())
    private let task: OSAllocatedUnfairLock<Task<Void, Never>?> = OSAllocatedUnfairLock(initialState: nil)

    var events: [SSEEvent] { captured.withLock { $0.events } }
    var rawLines: [String] { captured.withLock { $0.rawLines } }
    var status: Int? { captured.withLock { $0.status } }
    var finished: Bool { captured.withLock { $0.finished } }

    /// Opens `/events`. Returns once the response head has arrived.
    @MainActor
    static func open(_ harness: Harness, token: String? = nil, waitForFirstEvent: Bool = true) async throws -> EventCollector {
        let collector = EventCollector()
        var request = URLRequest(url: harness.baseURL.appending(path: "events"))
        request.setValue("Bearer \(token ?? harness.token)", forHTTPHeaderField: "Authorization")
        let session = harness.session
        let running = Task {
            do {
                let (bytes, response) = try await session.bytes(for: request)
                collector.captured.withLock { $0.status = (response as? HTTPURLResponse)?.statusCode }

                // Raw lines for the wire-level assertions, parsed events for the rest. One pass over
                // the bytes feeds both.
                var parser = SSEParser()
                var line: [UInt8] = []
                for try await byte in bytes {
                    if byte == 0x0A {
                        let text = String(decoding: line, as: UTF8.self)
                        collector.captured.withLock { $0.rawLines.append(text) }
                        line.removeAll()
                    } else {
                        line.append(byte)
                    }
                    let parsed = parser.feed(bytes: [byte])
                    if !parsed.isEmpty { collector.captured.withLock { $0.events += parsed } }
                }
            } catch {
                // Cancelled by `close()`, or the server hung up.
            }
            collector.captured.withLock { $0.finished = true }
        }
        collector.task.withLock { $0 = running }

        if waitForFirstEvent {
            try await withTimeout(.seconds(5)) {
                while collector.events.isEmpty, !collector.finished {
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
        }
        return collector
    }

    func close() {
        task.withLock { $0?.cancel() }
    }

    /// Waits until `condition` holds for the events so far.
    func wait(
        _ limit: Duration = .seconds(5),
        sourceLocation: SourceLocation = #_sourceLocation,
        until condition: @escaping @Sendable ([SSEEvent]) -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if condition(events) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("event condition never held; events so far: \(events.map { "\($0.event ?? "-") \($0.data.prefix(60))" })", sourceLocation: sourceLocation)
        return false
    }
}

extension SSEEvent {
    func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        try APIJSON.makeDecoder().decode(type, from: Data(data.utf8))
    }
}
