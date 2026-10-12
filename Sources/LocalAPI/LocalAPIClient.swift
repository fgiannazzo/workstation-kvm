import Actions
import Foundation
import SwitchboardCore
import TinyHTTP

/// A Swift client for the local API in `docs/API.md`; `switchboardctl` is built on it.
///
/// Every call is one request with a deadline. `events()` holds one long-lived request and ends
/// when the server closes it; it does not reconnect (a command line tool wants to know).
///
/// The token goes in an `Authorization: Bearer` header on every request except `GET /health`.
/// It is never put in a URL.
public struct LocalAPIClient: Sendable {
    public static let defaultPort = 48600
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:\(defaultPort)")!

    /// `docs/API.md`: a client may treat 45 s without a byte as a dead connection (the server
    /// sends a keepalive every 15 s).
    public static let eventSilenceLimit: TimeInterval = 45

    public let baseURL: URL
    private let token: String?
    private let timeout: TimeInterval
    private let session: URLSession

    /// - Parameters:
    ///   - baseURL: where the API listens; `http://127.0.0.1:48600` by default.
    ///   - token: the bearer token; nil for `health()` only.
    ///   - timeout: seconds before a request that has no answer gives up (`unreachable`).
    ///   - session: replaces the default loopback session, for tests.
    public init(baseURL: URL = LocalAPIClient.defaultBaseURL, token: String?, timeout: TimeInterval = 5, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.token = token
        self.timeout = timeout
        self.session = session ?? Self.loopbackSession
    }

    /// `http://127.0.0.1:<port>`.
    public static func baseURL(port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)") ?? defaultBaseURL
    }

    /// An ephemeral session that ignores system proxy settings, since this client only ever talks
    /// to the loopback interface, and a PAC file has no business with it.
    private static let loopbackSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    // MARK: Calls

    /// `GET /health`, without a token.
    public func health() async throws -> HealthResponse {
        try await get("health", authorized: false)
    }

    /// `GET /state`.
    public func state() async throws -> SwitchboardState {
        try await get("state")
    }

    /// `GET /actions`.
    public func actions() async throws -> ActionList {
        try await get("actions")
    }

    /// `GET /macros`.
    public func macros() async throws -> MacroFile {
        try await get("macros")
    }

    /// `POST /run/{id}`: starts the macro or action and returns its handle (`202`). Progress
    /// arrives on `events()`. A refusal is `LocalAPIError.status`: 400 missing or invalid
    /// parameter, 404 unknown id, 409 busy (see `LocalAPIError.errorBody`).
    public func run(id: String, parameters: [String: JSONValue] = [:]) async throws -> RunHandle {
        var request = makeRequest(method: "POST", components: ["run", id])
        if !parameters.isEmpty {
            request.httpBody = try APIJSON.makeEncoder().encode(parameters)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await decode(RunHandle.self, from: perform(request))
    }

    /// `GET /events`: the current state first, then every `state` and `run` event, until the
    /// consumer stops iterating (which closes the connection) or the server does. A server that
    /// closes the stream ends the sequence normally; a refusal or a dropped connection throws.
    public func events() -> AsyncThrowingStream<APIEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await pumpEvents(into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Requests

    private func makeRequest(method: String, components: [String], authorized: Bool = true, timeout: TimeInterval? = nil) -> URLRequest {
        var url = baseURL
        for component in components {
            url.append(component: component)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout ?? self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authorized, let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func get<T: Decodable>(_ path: String, authorized: Bool = true) async throws -> T {
        let request = makeRequest(method: "GET", components: [path], authorized: authorized)
        return try await decode(T.self, from: perform(request))
    }

    /// Sends the request and returns the body of a 2xx answer.
    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.map(error, url: baseURL)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LocalAPIError.invalidResponse("not an HTTP response")
        }
        try Self.check(http.statusCode, body: { String(decoding: data, as: UTF8.self) })
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try APIJSON.makeDecoder().decode(type, from: data)
        } catch {
            let preview = String(decoding: data.prefix(120), as: UTF8.self)
            throw LocalAPIError.invalidResponse("not a \(type) (\(error.localizedDescription)): \(preview)")
        }
    }

    private static func check(_ status: Int, body: () -> String) throws {
        switch status {
        case 200..<300: return
        case 401: throw LocalAPIError.unauthorized
        default: throw LocalAPIError.status(status, body: body())
        }
    }

    /// Transport failures become `unreachable`; cancellation stays cancellation.
    static func map(_ error: any Error, url: URL) -> any Error {
        if error is CancellationError || error is LocalAPIError { return error }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return CancellationError()
            case .badServerResponse, .cannotParseResponse, .zeroByteResource, .httpTooManyRedirects:
                return LocalAPIError.invalidResponse(urlError.localizedDescription)
            default:
                return LocalAPIError.unreachable(url, underlying: urlError.localizedDescription)
            }
        }
        return LocalAPIError.unreachable(url, underlying: error.localizedDescription)
    }

    // MARK: Events

    private func pumpEvents(into continuation: AsyncThrowingStream<APIEvent, any Error>.Continuation) async {
        do {
            var request = makeRequest(method: "GET", components: ["events"], timeout: Self.eventSilenceLimit)
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LocalAPIError.invalidResponse("not an HTTP response")
            }
            if !(200..<300).contains(http.statusCode) {
                var body = Data()
                for try await byte in bytes {
                    body.append(byte)
                    if body.count >= 4096 { break }
                }
                try Self.check(http.statusCode, body: { String(decoding: body, as: UTF8.self) })
            }

            let decoder = APIJSON.makeDecoder()
            for try await message in SSEParser.events(from: bytes) {
                let data = Data(message.data.utf8)
                switch message.event {
                case "state":
                    continuation.yield(.state(try decodeEvent(SwitchboardState.self, "state", data, with: decoder)))
                case "run":
                    continuation.yield(.run(try decodeEvent(RunEvent.self, "run", data, with: decoder)))
                default:
                    continue   // unknown event names are ignored, as API.md says of unknown fields
                }
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: Self.map(error, url: baseURL))
        }
    }

    private func decodeEvent<T: Decodable>(_ type: T.Type, _ name: String, _ data: Data, with decoder: JSONDecoder) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            let preview = String(decoding: data.prefix(120), as: UTF8.self)
            throw LocalAPIError.invalidResponse("\(name) event is not a \(type) (\(error.localizedDescription)): \(preview)")
        }
    }
}
