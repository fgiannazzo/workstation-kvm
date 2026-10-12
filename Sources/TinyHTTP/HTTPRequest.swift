import Foundation

/// A parsed HTTP request.
///
/// `path` is percent-decoded and carries no query string; `query` holds the
/// decoded query parameters (`+` is treated as a space there, as in form
/// encoding). Header names are lower-cased.
public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data

    public init(
        method: String,
        path: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers.reduce(into: [:]) { result, pair in
            let key = pair.key.lowercased()
            if let existing = result[key] {
                result[key] = existing + ", " + pair.value
            } else {
                result[key] = pair.value
            }
        }
        self.body = body
    }

    /// Case-insensitive header lookup.
    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// Decodes the body as JSON.
    public func json<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(type, from: body)
    }

    /// The token from an `Authorization: Bearer <token>` header, if present.
    public var bearerToken: String? {
        guard let value = headers["authorization"] else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].caseInsensitiveCompare("Bearer") == .orderedSame else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}
