import ESP32Kit
import Foundation
import os
import SwitchboardCore
import Testing
import TinyHTTP

struct TimeoutError: Error {}

/// Runs `body` with a deadline so a hang fails the test instead of the suite. The body must be
/// cancellable (URLSession, AsyncStream and Task.sleep all are).
func withTimeout<T: Sendable>(_ limit: Duration = .seconds(5), _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw TimeoutError() }
        return result
    }
}

/// A clock the test moves by hand, for `MockESP32`'s uptime.
final class TestClock: Sendable {
    private let current: OSAllocatedUnfairLock<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = OSAllocatedUnfairLock(initialState: start)
    }

    var now: Date { current.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// The state a fresh mock starts in, with a fixed uptime.
func briefState(uptime: Int = 123) -> ControllerState {
    ControllerState(
        hdmi: [.dualup: 1, .lg4k: 1, .samsung: 1],
        usb: .init(port: 1, source: "aten"),
        uptime: uptime
    )
}

/// Starts a mock on an ephemeral loopback port with a frozen clock, runs `body`, stops it.
func withMock<T>(
    initialState: ControllerState? = nil,
    pulseDelay: Duration = .zero,
    keepaliveInterval: Duration = .seconds(15),
    _ body: (MockESP32, URL) async throws -> T
) async throws -> T {
    let clock = TestClock()
    let mock = MockESP32(
        initialState: initialState,
        pulseDelay: pulseDelay,
        keepaliveInterval: keepaliveInterval,
        now: { clock.now }
    )
    try await mock.start()
    let url = try #require(await mock.url)
    do {
        let result = try await body(mock, url)
        await mock.stop()
        return result
    } catch {
        await mock.stop()
        throw error
    }
}

func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    return URLSession(configuration: configuration)
}

struct RawReply {
    let status: Int
    let body: Data
    var text: String { String(decoding: body, as: UTF8.self) }
    var object: [String: Any]? { try? JSONSerialization.jsonObject(with: body) as? [String: Any] }
}

/// One plain HTTP request, bypassing `ESP32Client`, so tests can send what the client cannot.
func rawRequest(_ method: String, _ url: URL, path: String, body: String? = nil) async throws -> RawReply {
    var request = URLRequest(url: url.appending(path: path))
    request.httpMethod = method
    if let body {
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await makeSession().data(for: request)
    return RawReply(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
}

/// Polls `condition` until it is true or `limit` passes.
func eventually(within limit: Duration = .seconds(3), _ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now + limit
    while clock.now < end {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Asserts that `body` throws a `ControllerError` and hands it back for further matching.
func controllerError(
    _ body: @Sendable () async throws -> some Any,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> ControllerError? {
    do {
        _ = try await body()
        Issue.record("expected a ControllerError, but the call succeeded", sourceLocation: sourceLocation)
        return nil
    } catch let error as ControllerError {
        return error
    } catch {
        Issue.record("expected a ControllerError, got \(error)", sourceLocation: sourceLocation)
        return nil
    }
}
