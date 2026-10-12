import Foundation

/// A request head that could not be accepted. The server answers with
/// `status` and closes the connection.
struct HTTPWireError: Error, Sendable {
    var status: Int
    var message: String
}

struct ParsedRequestHead: Sendable {
    var method: String
    var target: String
    var version: String
    var headers: [String: String]
    /// Bytes consumed from the buffer, including the terminating blank line.
    var length: Int
}

/// Byte-level HTTP/1.x helpers. Pure functions; no I/O.
enum HTTPWire {
    static let maxHeaderBytes = 64 * 1024
    static let maxBodyBytes = 1024 * 1024

    private static let crlfcrlf = Data("\r\n\r\n".utf8)
    private static let lflf = Data("\n\n".utf8)

    /// Parses a request head from the start of `buffer`.
    /// Returns nil when the head is not complete yet.
    static func parseHead(_ buffer: Data) throws(HTTPWireError) -> ParsedRequestHead? {
        // Tolerate bare LF line endings as well as CRLF.
        let crlfEnd = buffer.range(of: crlfcrlf)
        let lfEnd = buffer.range(of: lflf)
        let terminator: Range<Int>?
        switch (crlfEnd, lfEnd) {
        case let (a?, b?): terminator = a.lowerBound < b.lowerBound ? a : b
        case let (a?, nil): terminator = a
        case let (nil, b?): terminator = b
        case (nil, nil): terminator = nil
        }
        guard let terminator else {
            if buffer.count > maxHeaderBytes {
                throw HTTPWireError(status: 431, message: "request header too large")
            }
            return nil
        }
        if terminator.upperBound > maxHeaderBytes {
            throw HTTPWireError(status: 431, message: "request header too large")
        }

        let headText = String(decoding: buffer[buffer.startIndex..<(buffer.startIndex + terminator.lowerBound)], as: UTF8.self)
        var lines = headText.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
        // RFC 9112 §2.2: ignore at least one empty line before the request-line.
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        guard let requestLine = lines.first else {
            throw HTTPWireError(status: 400, message: "empty request")
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3 else {
            throw HTTPWireError(status: 400, message: "malformed request line")
        }
        let method = String(parts[0])
        let target = String(parts[1])
        let version = String(parts[2])
        guard version.hasPrefix("HTTP/1.") else {
            throw HTTPWireError(status: version.hasPrefix("HTTP/") ? 505 : 400, message: "unsupported HTTP version")
        }
        guard method.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else {
            throw HTTPWireError(status: 400, message: "malformed method")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            if line.first == " " || line.first == "\t" {
                throw HTTPWireError(status: 400, message: "obsolete header line folding is not supported")
            }
            guard let colon = line.firstIndex(of: ":") else {
                throw HTTPWireError(status: 400, message: "malformed header line")
            }
            let name = line[..<colon]
            guard !name.isEmpty, !name.contains(where: { $0.isWhitespace }) else {
                throw HTTPWireError(status: 400, message: "malformed header name")
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let key = name.lowercased()
            if let existing = headers[key] {
                headers[key] = existing + ", " + value
            } else {
                headers[key] = value
            }
        }

        return ParsedRequestHead(
            method: method,
            target: target,
            version: version,
            headers: headers,
            length: terminator.upperBound
        )
    }

    /// Splits a request target into a decoded path and decoded query parameters.
    static func parseTarget(_ target: String) -> (path: String, query: [String: String]) {
        var rest = Substring(target)
        // absolute-form: strip scheme and authority.
        if rest.hasPrefix("http://") || rest.hasPrefix("https://") {
            let afterScheme = rest.index(rest.startIndex, offsetBy: rest.hasPrefix("https://") ? 8 : 7)
            if let slash = rest[afterScheme...].firstIndex(of: "/") {
                rest = rest[slash...]
            } else {
                rest = "/"
            }
        }
        if let hash = rest.firstIndex(of: "#") {
            rest = rest[..<hash]
        }
        let rawPath: Substring
        var query: [String: String] = [:]
        if let q = rest.firstIndex(of: "?") {
            rawPath = rest[..<q]
            for pair in rest[rest.index(after: q)...].split(separator: "&", omittingEmptySubsequences: true) {
                if let eq = pair.firstIndex(of: "=") {
                    let key = percentDecode(pair[..<eq], plusAsSpace: true)
                    let value = percentDecode(pair[pair.index(after: eq)...], plusAsSpace: true)
                    query[key] = value
                } else {
                    query[percentDecode(pair, plusAsSpace: true)] = ""
                }
            }
        } else {
            rawPath = rest
        }
        let path = percentDecode(rawPath, plusAsSpace: false)
        return (path.isEmpty ? "/" : path, query)
    }

    /// Lenient percent-decoding: malformed escapes are kept verbatim and the
    /// result is decoded as UTF-8 with replacement characters where needed.
    static func percentDecode(_ input: Substring, plusAsSpace: Bool) -> String {
        let bytes = Array(input.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x25, i + 2 < bytes.count, let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
                out.append(hi << 4 | lo)
                i += 3
            } else if plusAsSpace, b == 0x2B {
                out.append(0x20)
                i += 1
            } else {
                out.append(b)
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    /// Whether the connection should stay open after this request.
    static func wantsKeepAlive(version: String, headers: [String: String]) -> Bool {
        let tokens = (headers["connection"] ?? "")
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if version == "HTTP/1.0" {
            return tokens.contains("keep-alive")
        }
        return !tokens.contains("close")
    }

    /// Serialises a buffered response. `Content-Length`, `Connection`,
    /// `Transfer-Encoding` are always set by the server; `Date` and `Server`
    /// are added unless the handler supplied them.
    static func serialize(_ response: HTTPResponse, isHead: Bool, keepAlive: Bool) -> Data {
        let hasBody = allowsBody(status: response.status)
        var head = statusLine(response.status)
        head += userHeaders(response.headers)
        if hasBody {
            head += "Content-Length: \(response.body.count)\r\n"
        }
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var data = Data(head.utf8)
        if hasBody && !isHead {
            data.append(response.body)
        }
        return data
    }

    /// Serialises the head of an event-stream response (no body framing: the
    /// stream ends when the connection closes).
    static func serializeStreamHead(_ response: HTTPResponse) -> Data {
        var head = statusLine(response.status)
        var headers = response.headers
        let lowered = Set(headers.keys.map { $0.lowercased() })
        if !lowered.contains("content-type") { headers["Content-Type"] = "text/event-stream" }
        if !lowered.contains("cache-control") { headers["Cache-Control"] = "no-cache" }
        head += userHeaders(headers)
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8)
    }

    private static func statusLine(_ status: Int) -> String {
        "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
    }

    private static func userHeaders(_ headers: [String: String]) -> String {
        var out = ""
        var seen = Set<String>()
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            let key = name.lowercased()
            // Framing headers are owned by the server.
            if key == "content-length" || key == "connection" || key == "transfer-encoding" { continue }
            seen.insert(key)
            out += "\(sanitizeHeader(name)): \(sanitizeHeader(value))\r\n"
        }
        if !seen.contains("date") { out += "Date: \(httpDate())\r\n" }
        if !seen.contains("server") { out += "Server: TinyHTTP\r\n" }
        return out
    }

    private static func sanitizeHeader(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0 != "\r" && $0 != "\n" })
    }

    static func allowsBody(status: Int) -> Bool {
        !(status == 204 || status == 304 || (100..<200).contains(status))
    }

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Content Too Large"
        case 415: return "Unsupported Media Type"
        case 422: return "Unprocessable Content"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        case 505: return "HTTP Version Not Supported"
        default: return "Status \(status)"
        }
    }

    private static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// RFC 9110 IMF-fixdate, e.g. `Sat, 11 Oct 2026 20:15:03 GMT`.
    static func httpDate(_ date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        func pad(_ value: Int?) -> String {
            let v = value ?? 0
            return v < 10 ? "0\(v)" : "\(v)"
        }
        let day = dayNames[max(0, min(6, (c.weekday ?? 1) - 1))]
        let month = monthNames[max(0, min(11, (c.month ?? 1) - 1))]
        return "\(day), \(pad(c.day)) \(month) \(c.year ?? 1970) \(pad(c.hour)):\(pad(c.minute)):\(pad(c.second)) GMT"
    }
}
