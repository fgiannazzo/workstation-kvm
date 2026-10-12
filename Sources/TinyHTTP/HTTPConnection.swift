import Foundation
import Network

/// Serves one accepted TCP connection: the HTTP/1.1 keep-alive loop, request
/// bodies by `Content-Length`, and event streams.
///
/// All I/O goes through `awaitCallback`, so a pending receive or send is
/// abandoned promptly when the task is cancelled; the `NWConnection` itself is
/// cancelled by `run()` on the way out.
actor HTTPConnection {
    private let connection: NWConnection
    private let handler: HTTPServer.Handler
    private let queue: DispatchQueue
    private var eofSeen = false

    init(connection: NWConnection, handler: @escaping HTTPServer.Handler, queue: DispatchQueue) {
        self.connection = connection
        self.handler = handler
        self.queue = queue
    }

    /// Runs until the connection is closed. Never throws.
    func run() async {
        await withTaskCancellationHandler {
            await serve()
            connection.cancel()
        } onCancel: {
            connection.cancel()
        }
    }

    private func serve() async {
        do {
            try await waitUntilReady()
            try await requestLoop()
        } catch {
            // Peer went away, I/O error or cancellation: nothing left to do but close.
        }
    }

    // MARK: Request loop

    private func requestLoop() async throws {
        var buffer = Data()
        while true {
            try Task.checkCancellation()

            let head: ParsedRequestHead
            do {
                guard let parsed = try await readHead(&buffer) else { return }
                head = parsed
            } catch let error as HTTPWireError {
                await respondAndClose(.error(error.message, status: error.status))
                return
            }
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + head.length))

            if head.headers["transfer-encoding"] != nil {
                await respondAndClose(.error("chunked request bodies are not supported; send Content-Length", status: 411))
                return
            }
            var contentLength = 0
            if let raw = head.headers["content-length"] {
                guard let length = Int(raw.trimmingCharacters(in: .whitespaces)), length >= 0 else {
                    await respondAndClose(.error("invalid Content-Length", status: 400))
                    return
                }
                guard length <= HTTPWire.maxBodyBytes else {
                    await respondAndClose(.error("request body too large", status: 413))
                    return
                }
                contentLength = length
            }
            if contentLength > 0, head.headers["expect"]?.lowercased() == "100-continue" {
                try await send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
            }
            while buffer.count < contentLength {
                guard let chunk = try await receive() else { return }
                buffer.append(chunk)
            }
            let body = Data(buffer.prefix(contentLength))
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + contentLength))

            let (path, query) = HTTPWire.parseTarget(head.target)
            let request = HTTPRequest(method: head.method, path: path, query: query, headers: head.headers, body: body)
            let keepAlive = HTTPWire.wantsKeepAlive(version: head.version, headers: head.headers)

            let response = await handler(request)

            if let producer = response.streamProducer {
                await streamEvents(response, producer: producer)
                return
            }
            try await send(HTTPWire.serialize(response, isHead: head.method == "HEAD", keepAlive: keepAlive))
            if !keepAlive {
                await halfClose()
                return
            }
        }
    }

    /// Reads until a complete request head is buffered. Nil means the peer
    /// closed the connection before (or while) sending one.
    private func readHead(_ buffer: inout Data) async throws -> ParsedRequestHead? {
        while true {
            if let parsed = try HTTPWire.parseHead(buffer) { return parsed }
            guard let chunk = try await receive() else { return nil }
            buffer.append(chunk)
        }
    }

    // MARK: Event streams

    private func streamEvents(_ response: HTTPResponse, producer: @escaping HTTPResponse.StreamProducer) async {
        do {
            try await send(HTTPWire.serializeStreamHead(response))
        } catch {
            return
        }
        let emitter = SSEEmitter { [self] data in try await self.send(data) }
        let connection = self.connection
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await producer(emitter) }
            group.addTask { [self] in await self.watchForDisconnect() }
            // Whichever happens first, producer returned or client gone, ends the stream.
            await group.next()
            await emitter.close()
            group.cancelAll()
            await halfClose()
            connection.cancel()
        }
    }

    /// Returns when the peer closes or the connection fails. Anything the
    /// client sends on an event-stream connection is ignored.
    private func watchForDisconnect() async {
        do {
            while try await receive() != nil {}
        } catch {}
    }

    // MARK: Closing

    private func respondAndClose(_ response: HTTPResponse) async {
        try? await send(HTTPWire.serialize(response, isHead: false, keepAlive: false))
        await drainAndClose(timeout: .seconds(2))
    }

    /// Half-closes, then discards whatever the peer is still sending until it
    /// closes too (or the timeout passes). Closing with unread data pending
    /// would send a reset and the client might never see the response.
    private func drainAndClose(timeout: Duration) async {
        await halfClose()
        let connection = self.connection
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in await self.watchForDisconnect() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                connection.cancel()
            }
            await group.next()
            group.cancelAll()
            connection.cancel()
        }
    }

    /// Sends FIN. Errors are irrelevant here: the peer may already be gone.
    private func halfClose() async {
        let connection = self.connection
        try? await awaitCallback { (done: @escaping @Sendable (Result<Void, any Error>) -> Void) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                done(.success(()))
            })
        }
    }

    // MARK: I/O primitives

    private func waitUntilReady() async throws {
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

    /// One chunk from the peer, or nil once the peer has closed its side.
    private func receive() async throws -> Data? {
        let connection = self.connection
        while !eofSeen {
            let (data, isComplete): (Data?, Bool) = try await awaitCallback { done in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let error {
                        done(.failure(error))
                    } else {
                        done(.success((data, isComplete)))
                    }
                }
            }
            if isComplete { eofSeen = true }
            if let data, !data.isEmpty { return data }
        }
        return nil
    }

    private func send(_ data: Data) async throws {
        let connection = self.connection
        try await awaitCallback { (done: @escaping @Sendable (Result<Void, any Error>) -> Void) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    done(.failure(error))
                } else {
                    done(.success(()))
                }
            })
        }
    }
}
