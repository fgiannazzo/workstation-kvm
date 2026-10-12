import Foundation
import Network

public enum HTTPServerError: Error, Sendable {
    /// `start()` was called on a server that is already running.
    case alreadyRunning
    case invalidPort
}

/// A Bonjour (mDNS) service to advertise while the server is running, e.g.
/// `BonjourService(name: "Switchboard Mock", type: "_switchboard._tcp")`.
public struct BonjourService: Sendable, Equatable {
    /// The service instance name shown to browsers.
    public var name: String
    /// The service type, e.g. `_switchboard._tcp`.
    public var type: String

    public init(name: String, type: String) {
        self.name = name
        self.type = type
    }
}

/// A small HTTP/1.1 server on Network.framework.
///
/// One task per connection; keep-alive for buffered responses; event streams
/// hold their connection open until the producer returns or the client leaves.
/// Limits: 64 KiB request head, 1 MiB request body (`Content-Length` only;
/// chunked request bodies are rejected with 411).
public actor HTTPServer {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private enum State: Equatable {
        case idle, starting, running, stopping
    }

    public nonisolated let host: String
    /// The port passed to `init`; zero means "pick a free port".
    public nonisolated let requestedPort: UInt16

    private let handler: Handler
    private let bonjour: BonjourService?
    private let queue = DispatchQueue(label: "TinyHTTP.HTTPServer")
    private var state: State = .idle
    private var listener: NWListener?
    private var connections: [UUID: Task<Void, Never>] = [:]

    /// The port actually bound. Valid after `start()` returns; zero when stopped.
    public private(set) var port: UInt16 = 0
    public var isRunning: Bool { state == .running }
    /// Connections accepted since `init` (diagnostics).
    public private(set) var acceptedConnectionCount = 0
    /// Connections currently open (diagnostics).
    public var activeConnectionCount: Int { connections.count }

    /// - Parameter bonjour: when non-nil, the listener advertises this service over mDNS for as
    ///   long as it runs. Bind to a LAN-reachable `host` (e.g. `0.0.0.0`) for the advertisement
    ///   to be useful; a loopback-only server is advertised too but nobody else can connect.
    public init(host: String = "127.0.0.1", port: UInt16 = 0, bonjour: BonjourService? = nil, handler: @escaping Handler) {
        self.host = host
        self.requestedPort = port
        self.bonjour = bonjour
        self.handler = handler
    }

    deinit {
        listener?.cancel()
        for task in connections.values {
            task.cancel()
        }
    }

    /// Binds and starts accepting. Throws if the address is in use or the
    /// listener fails for any other reason.
    public func start() async throws {
        guard state == .idle else { throw HTTPServerError.alreadyRunning }
        guard let nwPort = NWEndpoint.Port(rawValue: requestedPort) else { throw HTTPServerError.invalidPort }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let listener = try NWListener(using: parameters)
        if let bonjour {
            listener.service = NWListener.Service(name: bonjour.name, type: bonjour.type)
        }

        state = .starting
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { await self.accept(connection) }
        }

        let queue = self.queue
        do {
            try await awaitCallback(onCancel: { listener.cancel() }) { (done: @escaping @Sendable (Result<Void, any Error>) -> Void) in
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: done(.success(()))
                    case .failed(let error), .waiting(let error): done(.failure(error))
                    case .cancelled: done(.failure(CancellationError()))
                    case .setup: break
                    @unknown default: break
                    }
                }
                listener.start(queue: queue)
            }
        } catch {
            listener.cancel()
            state = .idle
            throw error
        }

        self.listener = listener
        self.port = listener.port?.rawValue ?? requestedPort
        state = .running
    }

    /// Stops accepting, closes every open connection and waits for their tasks
    /// to finish, then releases the port.
    public func stop() async {
        guard state == .running else { return }
        state = .stopping

        if let listener {
            self.listener = nil
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    try? await awaitCallback { (done: @escaping @Sendable (Result<Void, any Error>) -> Void) in
                        listener.stateUpdateHandler = { state in
                            if case .cancelled = state { done(.success(())) }
                        }
                        listener.cancel()
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(2))
                }
                await group.next()
                group.cancelAll()
            }
        }

        let tasks = Array(connections.values)
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
        connections.removeAll()
        port = 0
        state = .idle
    }

    private func accept(_ connection: NWConnection) {
        guard state == .starting || state == .running else {
            connection.cancel()
            return
        }
        acceptedConnectionCount += 1
        let id = UUID()
        let handler = self.handler
        let queue = self.queue
        let task = Task.detached { [weak self] in
            await HTTPConnection(connection: connection, handler: handler, queue: queue).run()
            await self?.connectionFinished(id)
        }
        // `accept` has no suspension point between creating the task and
        // registering it, so `connectionFinished` always runs after this line.
        connections[id] = task
    }

    private func connectionFinished(_ id: UUID) {
        connections[id] = nil
    }
}
