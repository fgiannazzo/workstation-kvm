import Foundation
import SwitchboardCore
import TinyHTTP

/// `ControllerClient` over HTTP, implementing the contract in `docs/ESP32-CONTRACT.md` against
/// the real ESP32 or `MockESP32`.
///
/// Every call is one HTTP request with a deadline (`timeout`, default 3 s). `events()` holds one
/// long-lived request open and reconnects by itself.
public final class ESP32Client: ControllerClient, Sendable {
    /// Reconnect schedule for `events()`: the first retry waits `initial`, each further failure
    /// doubles the wait, capped at `maximum` (1 s doubling to 30 s by default). A connection that
    /// delivered at least one state resets the schedule.
    public struct Backoff: Sendable, Equatable {
        public var initial: Duration
        public var maximum: Duration

        public init(initial: Duration, maximum: Duration) {
            self.initial = initial
            self.maximum = maximum
        }

        public static let `default` = Backoff(initial: .seconds(1), maximum: .seconds(30))
    }

    /// The silence limit on the event stream. The controller sends a keepalive every 15 s, so
    /// 45 s without a byte means the connection is dead (the same rule as `docs/API.md`).
    static let eventSilenceLimit: TimeInterval = 45

    public let baseURL: URL
    private let session: URLSession
    private let timeout: Duration
    private let backoff: Backoff

    public init(
        baseURL: URL,
        session: URLSession = .shared,
        timeout: Duration = .seconds(3),
        eventsBackoff: Backoff = .default
    ) {
        self.baseURL = baseURL
        self.session = session
        self.timeout = timeout
        self.backoff = eventsBackoff
    }

    // MARK: ControllerClient

    public func state() async throws -> ControllerState {
        try await send("GET", "state")
    }

    public func selectHDMI(_ display: DisplayID, input: Int) async throws -> ControllerState {
        try await send("POST", "hdmi/\(display.rawValue)/select", json: ["input": input])
    }

    public func resyncHDMI(_ display: DisplayID, input: Int) async throws -> ControllerState {
        try await send("POST", "hdmi/\(display.rawValue)/resync", json: ["input": input])
    }

    public func selectUSB(port: Int) async throws -> ControllerState {
        try await send("POST", "usb/select", json: ["port": port])
    }

    /// Every state the controller reports, starting with the current one on each (re)connect.
    /// The stream ends only when the consumer stops iterating; a lost connection is retried
    /// forever with the client's backoff.
    public func events() -> AsyncStream<ControllerState> {
        let (stream, continuation) = AsyncStream<ControllerState>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let task = Task { [self] in
            await pumpEvents(into: continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: Requests

    func url(for path: String) -> URL {
        baseURL.appending(path: path)
    }

    private func send(_ method: String, _ path: String, json: [String: Int]? = nil) async throws -> ControllerState {
        let url = url(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout.seconds
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.map(error, url: url)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ControllerError.invalidResponse("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ControllerError.httpStatus(http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return try Self.decodeState(data)
    }

    static func decodeState(_ data: Data) throws -> ControllerState {
        do {
            return try JSONDecoder().decode(ControllerState.self, from: data)
        } catch {
            let preview = String(decoding: data.prefix(120), as: UTF8.self)
            throw ControllerError.invalidResponse("not a state object (\(error.localizedDescription)): \(preview)")
        }
    }

    /// Maps transport failures onto `ControllerError`; cancellation stays cancellation.
    static func map(_ error: any Error, url: URL) -> any Error {
        if error is CancellationError || error is ControllerError { return error }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return CancellationError()
            case .timedOut:
                return ControllerError.timeout
            case .badServerResponse, .cannotParseResponse, .zeroByteResource, .httpTooManyRedirects:
                return ControllerError.invalidResponse(urlError.localizedDescription)
            default:
                return ControllerError.unreachable(url, underlying: urlError.localizedDescription)
            }
        }
        return ControllerError.unreachable(url, underlying: error.localizedDescription)
    }

    // MARK: Event stream

    private func pumpEvents(into continuation: AsyncStream<ControllerState>.Continuation) async {
        var wait = backoff.initial
        while !Task.isCancelled {
            let delivered = await streamOnce(into: continuation)
            if Task.isCancelled { return }
            if delivered { wait = backoff.initial }
            try? await Task.sleep(for: wait)
            wait = min(wait * 2, backoff.maximum)
        }
    }

    /// One connection. Returns whether at least one state was delivered before it ended.
    private func streamOnce(into continuation: AsyncStream<ControllerState>.Continuation) async -> Bool {
        var request = URLRequest(url: url(for: "events"))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.timeoutInterval = Self.eventSilenceLimit

        var delivered = false
        do {
            // Connecting and receiving the headers gets the normal request deadline; only a
            // connection that is up gets the long silence limit.
            let (bytes, response) = try await withDeadline(timeout) { [session, request] in
                try await session.bytes(for: request)
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            for try await event in SSEParser.events(from: bytes) {
                // The event name is ignored on purpose: any event whose data is a state counts.
                guard let state = try? JSONDecoder().decode(ControllerState.self, from: Data(event.data.utf8)) else { continue }
                delivered = true
                continuation.yield(state)
            }
        } catch {
            // Dropped, refused, timed out or cancelled: the caller backs off and reconnects.
        }
        return delivered
    }
}

extension Duration {
    /// The duration in (fractional) seconds.
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

/// Runs `operation`, giving up with `ControllerError.timeout` when it takes longer than `limit`.
/// The operation must be cancellable.
func withDeadline<T: Sendable>(
    _ limit: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw ControllerError.timeout
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw ControllerError.timeout }
        return first
    }
}
