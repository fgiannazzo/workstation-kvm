import Foundation
import Network
import Testing
@testable import TinyHTTP

struct TimeoutError: Error {}

/// Runs `body` with a deadline. The body must be cancellable (every await in
/// the tests is: URLSession, AsyncStream, Task.sleep).
func withTimeout<T: Sendable>(_ duration: Duration = .seconds(5), _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TimeoutError()
        }
        guard let result = try await group.next() else { throw TimeoutError() }
        group.cancelAll()
        return result
    }
}

/// Starts a server on an ephemeral loopback port, runs `body`, stops the server.
func withServer<T>(_ router: Router, _ body: (HTTPServer, URL) async throws -> T) async throws -> T {
    try await withServer(handler: router.handler, body)
}

func withServer<T>(handler: @escaping HTTPServer.Handler, _ body: (HTTPServer, URL) async throws -> T) async throws -> T {
    let server = HTTPServer(handler: handler)
    try await server.start()
    let port = await server.port
    let base = URL(string: "http://127.0.0.1:\(port)")!
    do {
        let result = try await body(server, base)
        await server.stop()
        return result
    } catch {
        await server.stop()
        throw error
    }
}

func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    return URLSession(configuration: configuration)
}

struct ErrorEnvelope: Codable, Equatable {
    var error: String
}

// MARK: - Raw TCP client for wire-level assertions

struct RawResponse {
    var status: Int
    var headers: [String: String]
    var body: Data
}

/// Talks HTTP/1.1 over a single `NWConnection`, so that keep-alive, HEAD and
/// error-close behaviour can be asserted byte for byte.
actor RawClient {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "RawClient")
    private var buffer = Data()
    private var eof = false

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func connect() async throws {
        let connection = self.connection
        let queue = self.queue
        try await awaitCallback(onCancel: { connection.cancel() }) { (done: @escaping @Sendable (Result<Void, any Error>) -> Void) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: done(.success(()))
                case .failed(let error), .waiting(let error): done(.failure(error))
                case .cancelled: done(.failure(CancellationError()))
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ text: String) async throws {
        try await send(Data(text.utf8))
    }

    func send(_ data: Data) async throws {
        let connection = self.connection
        try await awaitCallback { (done: @escaping @Sendable (Result<Void, any Error>) -> Void) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { done(.failure(error)) } else { done(.success(())) }
            })
        }
    }

    /// Nil once the server has closed its side.
    func receive() async throws -> Data? {
        let connection = self.connection
        while !eof {
            let (data, isComplete): (Data?, Bool) = try await awaitCallback { done in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let error { done(.failure(error)) } else { done(.success((data, isComplete))) }
                }
            }
            if isComplete { eof = true }
            if let data, !data.isEmpty { return data }
        }
        return nil
    }

    /// Reads one response. Needs a `Content-Length` (every buffered TinyHTTP response has one).
    func readResponse() async throws -> RawResponse {
        let head = try await readResponseHeadOnly()
        let length = Int(head.headers["content-length"] ?? "0") ?? 0
        return RawResponse(status: head.status, headers: head.headers, body: try await readBody(length))
    }

    /// Reads a status line and headers, leaving any body in the buffer (for HEAD).
    func readResponseHeadOnly() async throws -> RawResponse {
        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil {
            guard let chunk = try await receive() else { throw TimeoutError() }
            buffer.append(chunk)
        }
        let headEnd = buffer.range(of: separator)!
        let headText = String(decoding: buffer[buffer.startIndex..<headEnd.lowerBound], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex..<headEnd.upperBound)

        var lines = headText.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let status = Int(statusLine.split(separator: " ")[1])!
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return RawResponse(status: status, headers: headers, body: Data())
    }

    private func readBody(_ length: Int) async throws -> Data {
        while buffer.count < length {
            guard let chunk = try await receive() else { throw TimeoutError() }
            buffer.append(chunk)
        }
        let body = Data(buffer.prefix(length))
        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + length))
        return body
    }

    /// True when the server has closed the connection (no more bytes, EOF).
    func awaitEOF() async throws -> Bool {
        while let chunk = try await receive() {
            buffer.append(chunk)
        }
        return buffer.isEmpty
    }

    nonisolated func close() {
        connection.cancel()
    }
}
