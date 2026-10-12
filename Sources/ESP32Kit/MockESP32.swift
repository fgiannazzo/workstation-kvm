import Foundation
import SwitchboardCore
import TinyHTTP

/// A local stand-in for the ESP32 controller: the same HTTP contract (`docs/ESP32-CONTRACT.md`),
/// served by `TinyHTTP`, with the state kept in memory.
///
/// Used by the tests, by `switchboardctl controller mock` (for plugin and firmware developers)
/// and by the app when no controller is configured. It does not pulse or talk RS-485: a select
/// just sets the state, after an optional `pulseDelay` per simulated button press.
public actor MockESP32 {
    /// One request the mock served, in arrival order.
    public struct LoggedRequest: Sendable, Equatable {
        public let date: Date
        public let method: String
        public let path: String
        /// The request body as text (empty for GET).
        public let body: String
        /// The status the mock answered with (200 for an event stream).
        public let status: Int
    }

    public nonisolated let host: String
    public nonisolated let requestedPort: UInt16

    private let pulseDelay: Duration
    private let keepaliveInterval: Duration
    private let bonjourService: BonjourService?
    private let now: @Sendable () -> Date
    private let onRequest: (@Sendable (LoggedRequest) -> Void)?

    private var hdmi: [DisplayID: Int]
    private var usb: ControllerState.USB
    /// Uptime is `now - startDate`; `setState` moves `startDate` to make it match.
    private var startDate: Date
    private var server: HTTPServer?
    private var boundPort: UInt16 = 0
    private var lastPort: UInt16 = 0
    private var pendingFailures: [Int] = []
    private var log: [LoggedRequest] = []
    private var subscribers: [UUID: AsyncStream<ControllerState>.Continuation] = [:]

    /// - Parameters:
    ///   - host: interface to bind; `0.0.0.0` to be reachable from the LAN.
    ///   - port: 0 picks a free port (read it back from `port` after `start()`).
    ///   - initialState: defaults to every display on input 1 and USB port 1 from `aten`.
    ///   - pulseDelay: simulated time per button press of an HDMI `select`; zero by default.
    ///   - keepaliveInterval: how often an idle `/events` connection gets `: keepalive`.
    ///   - bonjour: advertise `_switchboard._tcp` over mDNS while running.
    ///   - bonjourName: the advertised instance name.
    ///   - now: the clock behind `uptime`; tests pass a fixed one.
    ///   - onRequest: called after every request; `switchboardctl controller mock` prints with it.
    public init(
        host: String = "127.0.0.1",
        port: UInt16 = 0,
        initialState: ControllerState? = nil,
        pulseDelay: Duration = .zero,
        keepaliveInterval: Duration = .seconds(15),
        bonjour: Bool = false,
        bonjourName: String = "Switchboard Mock",
        now: @escaping @Sendable () -> Date = { Date() },
        onRequest: (@Sendable (LoggedRequest) -> Void)? = nil
    ) {
        self.host = host
        self.requestedPort = port
        self.pulseDelay = pulseDelay
        self.keepaliveInterval = keepaliveInterval
        self.bonjourService = bonjour ? BonjourService(name: bonjourName, type: ESP32Discovery.serviceType) : nil
        self.now = now
        self.onRequest = onRequest

        let initial = initialState ?? ControllerState(
            hdmi: Dictionary(uniqueKeysWithValues: DisplayID.allCases.map { ($0, 1) }),
            usb: .init(port: 1, source: "aten"),
            uptime: 0
        )
        self.hdmi = initial.hdmi
        self.usb = initial.usb
        self.startDate = now().addingTimeInterval(-TimeInterval(initial.uptime))
    }

    // MARK: Lifecycle

    /// Binds and starts serving. After a `stop()` it comes back on the same port, so a client
    /// that is reconnecting finds it again.
    public func start() async throws {
        guard server == nil else { throw HTTPServerError.alreadyRunning }
        let port = lastPort != 0 ? lastPort : requestedPort
        let server = HTTPServer(host: host, port: port, bonjour: bonjourService, handler: makeRouter().handler)
        try await server.start()
        self.server = server
        self.boundPort = await server.port
        self.lastPort = boundPort
    }

    /// Stops serving, closes every event stream and releases the port. The state is kept.
    public func stop() async {
        guard let server else { return }
        self.server = nil
        self.boundPort = 0
        await server.stop()
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    /// The bound port; 0 while stopped.
    public var port: UInt16 { boundPort }

    /// `http://host:port` while running, nil when stopped. A wildcard bind reports loopback.
    public var url: URL? {
        guard boundPort != 0 else { return nil }
        let reachable = (host == "0.0.0.0" || host == "::") ? "127.0.0.1" : host
        return URL(string: "http://\(reachable):\(boundPort)")
    }

    // MARK: Test hooks

    /// Answers the next request (whatever it is) with `status` and `{"error":"injected failure"}`
    /// without touching the state. Calls queue up: two calls fail the next two requests.
    public func failNextRequest(status: Int) {
        pendingFailures.append(status)
    }

    /// Replaces the whole state, as if the controller had been changed from the outside, and
    /// tells every event stream. `uptime` is honoured (it keeps counting from there).
    public func setState(_ state: ControllerState) {
        hdmi = state.hdmi
        usb = state.usb
        startDate = now().addingTimeInterval(-TimeInterval(state.uptime))
        publish()
    }

    /// The state as a client would see it right now.
    public var currentState: ControllerState {
        ControllerState(hdmi: hdmi, usb: usb, uptime: max(0, Int(now().timeIntervalSince(startDate))))
    }

    /// Every request served since `init`, oldest first.
    public var requestLog: [LoggedRequest] { log }

    /// Event streams currently open.
    public var eventSubscriberCount: Int { subscribers.count }

    // MARK: Routes

    private enum Route: Sendable {
        case state
        case hdmi(display: String?, pulse: Bool)
        case usb
        case events
    }

    private func makeRouter() -> Router {
        var router = Router()
        router.get("/state") { [weak self] request in
            await self?.handle(request, .state) ?? .error("mock stopped", status: 503)
        }
        router.post("/hdmi/:display/select") { [weak self] request, params in
            await self?.handle(request, .hdmi(display: params["display"], pulse: true)) ?? .error("mock stopped", status: 503)
        }
        router.post("/hdmi/:display/resync") { [weak self] request, params in
            await self?.handle(request, .hdmi(display: params["display"], pulse: false)) ?? .error("mock stopped", status: 503)
        }
        router.post("/usb/select") { [weak self] request in
            await self?.handle(request, .usb) ?? .error("mock stopped", status: 503)
        }
        router.get("/events") { [weak self] request in
            await self?.handle(request, .events) ?? .error("mock stopped", status: 503)
        }
        return router
    }

    /// Serves one request, with the failure hook and the request log around it.
    private func handle(_ request: HTTPRequest, _ route: Route) async -> HTTPResponse {
        let response: HTTPResponse
        if !pendingFailures.isEmpty {
            response = .error("injected failure", status: pendingFailures.removeFirst())
        } else {
            switch route {
            case .state: response = stateResponse()
            case .hdmi(let display, let pulse): response = await hdmiResponse(request, display: display, pulse: pulse)
            case .usb: response = usbResponse(request)
            case .events: response = eventsResponse()
            }
        }
        let entry = LoggedRequest(
            date: now(),
            method: request.method,
            path: request.path,
            body: String(decoding: request.body, as: UTF8.self),
            status: response.status
        )
        log.append(entry)
        onRequest?(entry)
        return response
    }

    private func stateResponse() -> HTTPResponse {
        .json(currentState, encoder: Self.encoder)
    }

    private func hdmiResponse(_ request: HTTPRequest, display: String?, pulse: Bool) async -> HTTPResponse {
        guard let display, let id = DisplayID(rawValue: display) else {
            return .error("unknown display", status: 404)
        }
        guard let value = Self.integer("input", in: request.body), (1...2).contains(value) else {
            return .error("invalid input", status: 400)
        }
        if pulse, hdmi[id] != value, pulseDelay > .zero {
            // A two-input switch needs one press to change input; the real controller waits
            // for each press to settle.
            try? await Task.sleep(for: pulseDelay)
        }
        if hdmi[id] != value {
            hdmi[id] = value
            publish()
        }
        return stateResponse()
    }

    private func usbResponse(_ request: HTTPRequest) -> HTTPResponse {
        guard let value = Self.integer("port", in: request.body), (1...4).contains(value) else {
            return .error("invalid port", status: 400)
        }
        if usb.port != value {
            usb.port = value
            publish()
        }
        return stateResponse()
    }

    /// `key` from a JSON object body as a whole number; nil for a missing key, a string, a
    /// boolean or a fraction.
    private static func integer(_ key: String, in body: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let number = object[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let double = number.doubleValue
        guard double == double.rounded(), abs(double) < 1_000_000 else { return nil }
        return Int(double)
    }

    private func eventsResponse() -> HTTPResponse {
        let keepalive = keepaliveInterval
        return .eventStream { [weak self] emitter in
            guard let self else { return }
            let (id, states) = await self.subscribe()
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await state in states {
                        guard let data = try? Self.encoder.encode(state) else { continue }
                        do {
                            try await emitter.send(event: "state", data: String(decoding: data, as: UTF8.self))
                        } catch {
                            return
                        }
                    }
                }
                group.addTask {
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: keepalive)
                            try await emitter.comment("keepalive")
                        } catch {
                            return
                        }
                    }
                }
                await group.next()
                group.cancelAll()
            }
            await self.unsubscribe(id)
        }
    }

    // MARK: Event fan-out

    /// Registers a stream that yields the current state immediately and every change after.
    private func subscribe() -> (UUID, AsyncStream<ControllerState>) {
        let (stream, continuation) = AsyncStream<ControllerState>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let id = UUID()
        subscribers[id] = continuation
        continuation.yield(currentState)
        return (id, stream)
    }

    private func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.finish()
    }

    /// Tells every open event stream the state is now `currentState`. A request that leaves the
    /// values as they were is not a change and sends nothing; `setState` always sends.
    private func publish() {
        let state = currentState
        for continuation in subscribers.values { continuation.yield(state) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
