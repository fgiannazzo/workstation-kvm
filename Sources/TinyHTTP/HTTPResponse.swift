import Foundation

/// An HTTP response.
///
/// A response is either buffered (`body` is sent with a `Content-Length`) or an
/// event stream (`streamProducer` is non-nil; `body` is ignored, the connection
/// is marked `Connection: close` and lives until the producer returns).
public struct HTTPResponse: Sendable {
    public typealias StreamProducer = @Sendable (SSEEmitter) async -> Void

    public var status: Int
    public var headers: [String: String]
    public var body: Data
    /// Non-nil for `text/event-stream` responses. See ``eventStream(_:)``.
    public var streamProducer: StreamProducer?

    public var isEventStream: Bool { streamProducer != nil }

    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
        self.streamProducer = nil
    }

    // MARK: Buffered helpers

    /// JSON-encodes `value`. If encoding fails the response is a 500 with an
    /// `{"error": ...}` body, so handlers never have to deal with the error.
    public static func json<T: Encodable>(_ value: T, status: Int = 200, encoder: JSONEncoder = JSONEncoder()) -> HTTPResponse {
        do {
            let data = try encoder.encode(value)
            return HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
        } catch {
            return .error("response encoding failed", status: 500)
        }
    }

    public static func text(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(string.utf8))
    }

    public static func empty(status: Int = 204) -> HTTPResponse {
        HTTPResponse(status: status)
    }

    /// `{"error": message}` with the given status.
    public static func error(_ message: String, status: Int) -> HTTPResponse {
        .json(ErrorBody(error: message), status: status)
    }

    /// `404 {"error":"not found"}`
    public static var notFound: HTTPResponse { .error("not found", status: 404) }

    /// `401 {"error":"unauthorized"}`
    public static var unauthorized: HTTPResponse { .error("unauthorized", status: 401) }

    // MARK: Streaming

    /// A `text/event-stream` response. `producer` runs for the life of the
    /// connection; when it returns the connection is closed. If the client
    /// disconnects first, the producer's task is cancelled and the emitter
    /// reports `isClosed`.
    public static func eventStream(_ producer: @escaping StreamProducer) -> HTTPResponse {
        var response = HTTPResponse(
            status: 200,
            headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"]
        )
        response.streamProducer = producer
        return response
    }
}

struct ErrorBody: Codable, Sendable {
    var error: String
}
