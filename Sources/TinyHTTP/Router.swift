import Foundation

/// Method + path-pattern dispatch for ``HTTPServer``.
///
/// ```swift
/// var router = Router()
/// router.get("/state") { request in .json(state) }
/// router.post("/run/:id") { request, params in .json(["id": params["id"]!], status: 202) }
/// let server = HTTPServer(port: 48600, handler: router.handler)
/// ```
///
/// Patterns are matched segment by segment; `:name` captures one segment and a
/// trailing `*` captures the rest under `params["*"]`. A path that matches a
/// route with a different method yields 405 with an `Allow` header; `HEAD`
/// falls back to `GET` routes; anything else goes to `fallback` (404 by default).
public struct Router: Sendable {
    public typealias Parameters = [String: String]
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse
    public typealias ParameterizedHandler = @Sendable (HTTPRequest, Parameters) async -> HTTPResponse

    private enum Segment: Sendable, Equatable {
        case literal(String)
        case parameter(String)
        case wildcard
    }

    private struct Route: Sendable {
        var method: String
        var segments: [Segment]
        var handler: ParameterizedHandler
    }

    private var routes: [Route] = []

    /// Invoked when no route matches. Defaults to `404 {"error":"not found"}`.
    public var fallback: Handler = { _ in .notFound }

    public init() {}

    // MARK: Registration

    public mutating func add(_ method: String, _ pattern: String, _ handler: @escaping ParameterizedHandler) {
        routes.append(Route(method: method.uppercased(), segments: Router.segments(of: pattern), handler: handler))
    }

    public mutating func add(_ method: String, _ pattern: String, _ handler: @escaping Handler) {
        add(method, pattern) { request, _ in await handler(request) }
    }

    public mutating func get(_ pattern: String, _ handler: @escaping Handler) { add("GET", pattern, handler) }
    public mutating func get(_ pattern: String, _ handler: @escaping ParameterizedHandler) { add("GET", pattern, handler) }
    public mutating func post(_ pattern: String, _ handler: @escaping Handler) { add("POST", pattern, handler) }
    public mutating func post(_ pattern: String, _ handler: @escaping ParameterizedHandler) { add("POST", pattern, handler) }
    public mutating func put(_ pattern: String, _ handler: @escaping Handler) { add("PUT", pattern, handler) }
    public mutating func put(_ pattern: String, _ handler: @escaping ParameterizedHandler) { add("PUT", pattern, handler) }
    public mutating func patch(_ pattern: String, _ handler: @escaping Handler) { add("PATCH", pattern, handler) }
    public mutating func patch(_ pattern: String, _ handler: @escaping ParameterizedHandler) { add("PATCH", pattern, handler) }
    public mutating func delete(_ pattern: String, _ handler: @escaping Handler) { add("DELETE", pattern, handler) }
    public mutating func delete(_ pattern: String, _ handler: @escaping ParameterizedHandler) { add("DELETE", pattern, handler) }

    // MARK: Dispatch

    /// The closure to hand to ``HTTPServer``. Captures the routes registered so
    /// far; later registrations do not affect it.
    public var handler: Handler {
        let routes = self.routes
        let fallback = self.fallback
        return { request in
            let path = Router.pathSegments(of: request.path)
            var allowed: [String] = []
            for route in routes {
                guard let params = Router.match(route.segments, against: path) else { continue }
                if route.method == request.method || (request.method == "HEAD" && route.method == "GET") {
                    return await route.handler(request, params)
                }
                if !allowed.contains(route.method) {
                    allowed.append(route.method)
                }
            }
            if !allowed.isEmpty {
                var response = HTTPResponse.error("method not allowed", status: 405)
                response.headers["Allow"] = allowed.sorted().joined(separator: ", ")
                return response
            }
            return await fallback(request)
        }
    }

    // MARK: Matching

    private static func segments(of pattern: String) -> [Segment] {
        pattern.split(separator: "/", omittingEmptySubsequences: true).map { piece in
            if piece == "*" { return .wildcard }
            if piece.hasPrefix(":") { return .parameter(String(piece.dropFirst())) }
            return .literal(String(piece))
        }
    }

    private static func pathSegments(of path: String) -> [Substring] {
        path.split(separator: "/", omittingEmptySubsequences: true)
    }

    private static func match(_ pattern: [Segment], against path: [Substring]) -> Parameters? {
        var params: Parameters = [:]
        var index = 0
        for segment in pattern {
            switch segment {
            case .wildcard:
                params["*"] = path[index...].joined(separator: "/")
                return params
            case .literal(let text):
                guard index < path.count, path[index] == text else { return nil }
            case .parameter(let name):
                guard index < path.count else { return nil }
                params[name] = String(path[index])
            }
            index += 1
        }
        return index == path.count ? params : nil
    }
}
