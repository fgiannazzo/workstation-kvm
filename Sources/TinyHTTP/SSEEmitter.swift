import Foundation

public enum SSEEmitterError: Error, Sendable {
    /// The client has gone away or the stream has been closed.
    case closed
}

/// Writes server-sent events to one client connection.
///
/// The emitter is handed to the producer closure of
/// ``HTTPResponse/eventStream(_:)``. When the client disconnects the emitter
/// becomes closed, every further `send`/`comment` throws
/// ``SSEEmitterError/closed`` and the producer's task is cancelled.
public actor SSEEmitter {
    public typealias Writer = @Sendable (Data) async throws -> Void

    private let writer: Writer
    public private(set) var isClosed = false

    /// Creates an emitter over an arbitrary writer. The server uses this; it is
    /// public so that producers can be unit-tested against an in-memory sink.
    public init(writer: @escaping Writer) {
        self.writer = writer
    }

    /// Sends one event. Multi-line `data` becomes several `data:` lines.
    public func send(event: String? = nil, data: String, id: String? = nil) async throws {
        try await write(Data(SSEEmitter.format(event: event, data: data, id: id).utf8))
    }

    /// Sends a comment line (`: text`), e.g. a keepalive.
    public func comment(_ text: String) async throws {
        try await write(Data(SSEEmitter.formatComment(text).utf8))
    }

    /// Marks the stream closed. Idempotent. Called by the server when the
    /// client disconnects or the producer returns.
    public func close() {
        isClosed = true
    }

    private func write(_ data: Data) async throws {
        if isClosed { throw SSEEmitterError.closed }
        try Task.checkCancellation()
        do {
            try await writer(data)
        } catch {
            isClosed = true
            throw error
        }
    }

    // MARK: Wire format

    /// The wire form of one event, e.g. `"event: run\ndata: {...}\n\n"`.
    public static func format(event: String?, data: String, id: String? = nil) -> String {
        var out = ""
        if let event, !event.isEmpty {
            out += "event: \(sanitize(event))\n"
        }
        if let id {
            out += "id: \(sanitize(id))\n"
        }
        for line in data.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            out += "data: \(line)\n"
        }
        out += "\n"
        return out
    }

    /// The wire form of a comment, e.g. `": keepalive\n\n"`.
    public static func formatComment(_ text: String) -> String {
        var out = ""
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            out += ": \(line)\n"
        }
        out += "\n"
        return out
    }

    private static func sanitize(_ field: String) -> String {
        String(field.unicodeScalars.filter { $0 != "\n" && $0 != "\r" })
    }
}
