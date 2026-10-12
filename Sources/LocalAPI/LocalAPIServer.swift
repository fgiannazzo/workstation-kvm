import Actions
import Foundation
import StateStore
import SwitchboardCore
import TinyHTTP

/// The local API of `docs/API.md`: HTTP on the loopback interface, a bearer token on everything
/// but `GET /health`, and server-sent events on `GET /events`.
///
/// The server is a thin skin over a `Runtime`. It reads `runtime.store`, `runtime.registry` and
/// `runtime.macros`, starts runs on `runtime.runner`, and forwards `store.changes` and
/// `runner.events`. The app starts it with one line, which takes the port from
/// `runtime.settings.localAPIPort` and the token from the keychain (creating it on first launch):
///
/// ```swift
/// let api = try await LocalAPIServer.start(runtime: runtime)
/// ```
///
/// Binding is the caller's `host`, `127.0.0.1` unless a test needs another loopback address. The
/// token is checked before routing, so an unknown path or a wrong method without a token is `401`
/// as well and the API does not reveal what exists.
public actor LocalAPIServer {
    /// The silence between `: keepalive` comments (`docs/API.md`: every 15 s).
    public static let defaultKeepaliveInterval: Duration = .seconds(15)

    public nonisolated let host: String
    public nonisolated let version: String
    /// The port that was asked for; 0 means any free port.
    public nonisolated let requestedPort: UInt16

    private let http: HTTPServer
    /// The port actually bound, once `start()` has returned; the requested port before and after.
    public private(set) var port: UInt16

    /// - Parameters:
    ///   - runtime: what the API serves and runs.
    ///   - port: `Settings.localAPIPort`; 0 picks a free port (tests), read it back from `port`.
    ///   - token: the bearer token. An empty token authenticates nobody.
    ///   - version: what `GET /health` reports.
    ///   - host: the address to bind. Loopback only is the contract; this exists for tests.
    ///   - keepaliveInterval: how often an idle `/events` stream gets a `: keepalive` comment.
    public init(
        runtime: Runtime,
        port: UInt16,
        token: String,
        version: String = SwitchboardVersion.current,
        host: String = "127.0.0.1",
        keepaliveInterval: Duration = LocalAPIServer.defaultKeepaliveInterval
    ) {
        let api = APIHandler(runtime: runtime, token: token, version: version, keepaliveInterval: keepaliveInterval)
        self.host = host
        self.version = version
        self.requestedPort = port
        self.port = port
        self.http = HTTPServer(host: host, port: port) { request in await api.handle(request) }
    }

    /// Builds a server for `runtime` and starts it: the port is `runtime.settings.localAPIPort`
    /// and the token is the one in `tokenStore` (made and stored first when there is none; the
    /// login keychain by default). Throws `LocalAPIServerError.invalidPort` for a setting that is
    /// not a port number, the token store's error, or the listener's (the port is taken).
    ///
    /// Keep the returned server for as long as the API should run and call `stop()` on quit.
    public static func start(
        runtime: Runtime,
        tokenStore: some TokenStoring = KeychainTokenStore(),
        version: String = SwitchboardVersion.current
    ) async throws -> LocalAPIServer {
        let configured = runtime.settings.localAPIPort
        guard let port = UInt16(exactly: configured) else { throw LocalAPIServerError.invalidPort(configured) }
        let token = try TokenStore.loadOrCreate(using: tokenStore)
        let server = LocalAPIServer(runtime: runtime, port: port, token: token, version: version)
        try await server.start()
        return server
    }

    /// Binds and starts serving. Throws when the port is taken or cannot be bound.
    public func start() async throws {
        try await http.start()
        port = await http.port
    }

    /// Closes the listener and every open connection, `/events` streams included.
    public func stop() async {
        await http.stop()
        port = requestedPort
    }

    public var isRunning: Bool {
        get async { await http.isRunning }
    }

    /// Open client connections (event streams count). A test hook.
    public var activeConnectionCount: Int {
        get async { await http.activeConnectionCount }
    }

    /// `http://127.0.0.1:48600`, once started.
    public var url: URL? {
        port == 0 ? nil : URL(string: "http://\(host.contains(":") ? "[\(host)]" : host):\(port)")
    }
}

/// Why `LocalAPIServer.start(runtime:)` could not even try.
public enum LocalAPIServerError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    /// `Settings.localAPIPort` is outside 0...65535.
    case invalidPort(Int)

    public var description: String {
        switch self {
        case .invalidPort(let port):
            return "localAPIPort \(port) is not a port number (1 to 65535)"
        }
    }

    public var errorDescription: String? { description }
}

// MARK: - Handler

/// Everything the HTTP handler needs, as a `Sendable` value, so the closure given to `HTTPServer`
/// does not capture the actor.
struct APIHandler: Sendable {
    let runtime: Runtime
    let token: String
    let version: String
    let keepaliveInterval: Duration
    private let dispatch: Router.Handler

    init(runtime: Runtime, token: String, version: String, keepaliveInterval: Duration) {
        self.runtime = runtime
        self.token = token
        self.version = version
        self.keepaliveInterval = keepaliveInterval

        var router = Router()
        router.get("/health") { _ in
            APIHandler.json(HealthResponse(version: version))
        }
        router.get("/state") { _ in
            // StateStore is main-actor isolated; this is the one hop.
            let state = await MainActor.run { runtime.store.state }
            return APIHandler.json(state)
        }
        router.get("/actions") { _ in
            APIHandler.json(ActionList(actions: runtime.registry.descriptors))
        }
        router.get("/macros") { _ in
            do {
                return APIHandler.json(MacroFile(macros: try await runtime.macros.macros()))
            } catch {
                return APIHandler.json(APIErrorBody(error: "\(error)"), status: 500)
            }
        }
        router.post("/run/:id") { request, parameters in
            await APIHandler.run(request, id: parameters["id"] ?? "", runtime: runtime)
        }
        router.get("/events") { _ in
            .eventStream { emitter in
                await APIHandler.stream(runtime: runtime, to: emitter, keepalive: keepaliveInterval)
            }
        }
        self.dispatch = router.handler
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard isHealthCheck(request) || isAuthorized(request) else {
            return .unauthorized
        }
        return await dispatch(request)
    }

    /// `GET /health`, the only request that needs no token.
    private func isHealthCheck(_ request: HTTPRequest) -> Bool {
        guard request.method == "GET" || request.method == "HEAD" else { return false }
        return request.path.split(separator: "/", omittingEmptySubsequences: true) == ["health"]
    }

    /// `Authorization: Bearer <token>`, compared in constant time. The query string is never
    /// looked at, so a token in a URL is no token.
    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard let provided = request.bearerToken else { return false }
        return TokenStore.constantTimeEquals(provided, token)
    }

    // MARK: Responses

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        .json(value, status: status, encoder: APIJSON.makeEncoder())
    }

    // MARK: POST /run/{id}

    static func run(_ request: HTTPRequest, id: String, runtime: Runtime) async -> HTTPResponse {
        guard !id.isEmpty else { return .notFound }

        let parameters: [String: JSONValue]
        switch parseParameters(request.body) {
        case .success(let parsed): parameters = parsed
        case .failure(let failure): return json(APIErrorBody(error: "invalid body", reason: failure.message), status: 400)
        }

        do {
            let handle = try await runtime.runner.start(id: id, parameters: parameters)
            return json(handle, status: 202)
        } catch let error as ActionError {
            return response(for: error)
        } catch {
            return json(APIErrorBody(error: "\(error)"), status: 500)
        }
    }

    /// An empty body (or `null`) means no parameters; otherwise it must be a JSON object.
    static func parseParameters(_ body: Data) -> Result<[String: JSONValue], ParameterError> {
        if body.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return .success([:]) }
        do {
            switch try JSONDecoder().decode(JSONValue.self, from: body) {
            case .object(let object): return .success(object)
            case .null: return .success([:])
            default: return .failure(ParameterError(message: "expected a JSON object of parameters"))
            }
        } catch {
            return .failure(ParameterError(message: "the body is not valid JSON"))
        }
    }

    struct ParameterError: Error, Sendable {
        let message: String
    }

    /// The status and body `docs/API.md` gives each way `start` can refuse.
    static func response(for error: ActionError) -> HTTPResponse {
        switch error {
        case .unknownID(let id):
            return json(APIErrorBody(error: "unknown id", id: id), status: 404)
        case .missingParameter(let name):
            return json(APIErrorBody(error: "missing parameter", parameter: name), status: 400)
        case .invalidParameter(let name, let reason):
            return json(APIErrorBody(error: "invalid parameter", parameter: name, reason: reason), status: 400)
        case .busy(let runID):
            return json(APIErrorBody(error: "busy", runId: runID), status: 409)
        default:
            return json(APIErrorBody(error: "\(error)"), status: 500)
        }
    }

    // MARK: GET /events

    /// Runs for the life of one `/events` connection. The server ends it by cancelling the
    /// calling task when the client goes away, which stops all three forwarders and, through
    /// the streams' termination handlers, removes this connection's two subscriptions.
    static func stream(runtime: Runtime, to emitter: SSEEmitter, keepalive: Duration) async {
        // Subscribe to run events before the first state goes out, so a run that starts while
        // this client is connecting cannot slip between the two. `changes` starts with the
        // current state, which is the one `state` event every connection begins with.
        let runs = await runtime.runner.events
        let states = await runtime.store.changes

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await state in states {
                    guard await send("state", state, to: emitter) else { return }
                }
            }
            group.addTask {
                for await run in runs {
                    guard await send("run", run, to: emitter) else { return }
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: keepalive) } catch { return }
                    do { try await emitter.comment("keepalive") } catch { return }
                }
            }
            // The first to finish (the emitter closed, or the producer cancelled) ends all three.
            await group.next()
            group.cancelAll()
        }
    }

    /// One event with its JSON on a single `data:` line. False when the client is gone.
    private static func send<T: Encodable>(_ event: String, _ value: T, to emitter: SSEEmitter) async -> Bool {
        guard let data = try? APIJSON.makeEncoder().encode(value) else { return true }   // skip what cannot be encoded
        do {
            try await emitter.send(event: event, data: String(decoding: data, as: UTF8.self))
            return true
        } catch {
            return false
        }
    }
}
