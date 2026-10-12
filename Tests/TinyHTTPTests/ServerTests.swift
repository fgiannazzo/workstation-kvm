import Foundation
import Testing
@testable import TinyHTTP

struct Echo: Codable, Equatable {
    var method: String
    var path: String
    var query: [String: String]
    var header: String?
}

private func echoRouter() -> Router {
    var router = Router()
    router.get("/echo") { request in
        .json(Echo(method: request.method, path: request.path, query: request.query, header: request.header("X-Test")))
    }
    router.get("/café bar") { request in
        .json(Echo(method: request.method, path: request.path, query: request.query, header: nil))
    }
    router.post("/run/:id") { request, params in
        struct Body: Decodable { var port: Int }
        guard let body = try? request.json(Body.self) else { return .error("bad json", status: 400) }
        return .json(["id": params["id"] ?? "", "port": "\(body.port)"], status: 202)
    }
    router.get("/a/:x/b/:y") { _, params in .json(params) }
    router.get("/files/*") { _, params in .text(params["*"] ?? "") }
    router.get("/token") { request in .text(request.bearerToken ?? "none") }
    router.get("/secure") { request in request.bearerToken == "s3cret" ? .empty() : .unauthorized }
    return router
}

@Suite("HTTPServer")
struct ServerTests {
    @Test func getWithQueryAndHeadersRoundTrips() async throws {
        try await withServer(echoRouter()) { _, base in
            let url = base.appending(path: "echo").appending(queryItems: [
                URLQueryItem(name: "a", value: "1"),
                URLQueryItem(name: "b", value: "two words"),
            ])
            var request = URLRequest(url: url)
            request.setValue("hello", forHTTPHeaderField: "X-Test")
            let (data, response) = try await makeSession().data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200)
            #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")
            #expect(http.value(forHTTPHeaderField: "Server") == "TinyHTTP")
            #expect(http.value(forHTTPHeaderField: "Date")?.hasSuffix("GMT") == true)
            let echo = try JSONDecoder().decode(Echo.self, from: data)
            #expect(echo == Echo(method: "GET", path: "/echo", query: ["a": "1", "b": "two words"], header: "hello"))
        }
    }

    @Test func postJSONBodyIsDecodedAndPathParametersBound() async throws {
        try await withServer(echoRouter()) { _, base in
            var request = URLRequest(url: base.appending(path: "run/guest"))
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"port": 2}"#.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await makeSession().data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 202)
            let decoded = try JSONDecoder().decode([String: String].self, from: data)
            #expect(decoded == ["id": "guest", "port": "2"])
        }
    }

    @Test func pathParametersAndWildcard() async throws {
        try await withServer(echoRouter()) { _, base in
            let session = makeSession()
            let (data, _) = try await session.data(from: base.appending(path: "a/one/b/two"))
            #expect(try JSONDecoder().decode([String: String].self, from: data) == ["x": "one", "y": "two"])

            let (_, incomplete) = try await session.data(from: base.appending(path: "a/one"))
            #expect((incomplete as? HTTPURLResponse)?.statusCode == 404)

            let (rest, _) = try await session.data(from: base.appending(path: "files/x/y/z.txt"))
            #expect(String(decoding: rest, as: UTF8.self) == "x/y/z.txt")
        }
    }

    @Test func unknownPathFallsBackTo404() async throws {
        try await withServer(echoRouter()) { _, base in
            let (data, response) = try await makeSession().data(from: base.appending(path: "nope"))
            #expect((response as? HTTPURLResponse)?.statusCode == 404)
            #expect(try JSONDecoder().decode(ErrorEnvelope.self, from: data) == ErrorEnvelope(error: "not found"))
        }
    }

    @Test func wrongMethodIs405WithAllow() async throws {
        try await withServer(echoRouter()) { _, base in
            var request = URLRequest(url: base.appending(path: "echo"))
            request.httpMethod = "POST"
            let (_, response) = try await makeSession().data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 405)
            #expect(http.value(forHTTPHeaderField: "Allow") == "GET")
        }
    }

    @Test func bearerTokenExtraction() async throws {
        try await withServer(echoRouter()) { _, base in
            let session = makeSession()

            var request = URLRequest(url: base.appending(path: "token"))
            request.setValue("Bearer abc.def-123", forHTTPHeaderField: "Authorization")
            let (token, _) = try await session.data(for: request)
            #expect(String(decoding: token, as: UTF8.self) == "abc.def-123")

            let (none, _) = try await session.data(from: base.appending(path: "token"))
            #expect(String(decoding: none, as: UTF8.self) == "none")

            request.setValue("Basic abc", forHTTPHeaderField: "Authorization")
            let (basic, _) = try await session.data(for: request)
            #expect(String(decoding: basic, as: UTF8.self) == "none")

            var secure = URLRequest(url: base.appending(path: "secure"))
            secure.setValue("bearer s3cret", forHTTPHeaderField: "Authorization")
            let (_, ok) = try await session.data(for: secure)
            #expect((ok as? HTTPURLResponse)?.statusCode == 204)

            secure.setValue("Bearer wrong", forHTTPHeaderField: "Authorization")
            let (body, denied) = try await session.data(for: secure)
            #expect((denied as? HTTPURLResponse)?.statusCode == 401)
            #expect(try JSONDecoder().decode(ErrorEnvelope.self, from: body) == ErrorEnvelope(error: "unauthorized"))
        }
    }

    @Test func keepAliveWithURLSession() async throws {
        try await withServer(echoRouter()) { server, base in
            let session = makeSession()
            let (_, first) = try await session.data(from: base.appending(path: "echo"))
            #expect((first as? HTTPURLResponse)?.statusCode == 200)
            let (_, second) = try await session.data(from: base.appending(path: "echo"))
            #expect((second as? HTTPURLResponse)?.statusCode == 200)
            // Sequential requests on one session reuse the connection.
            #expect(await server.acceptedConnectionCount == 1)
        }
    }

    @Test func keepAliveAndPipeliningOnOneSocket() async throws {
        try await withServer(echoRouter()) { server, base in
            let client = RawClient(port: UInt16(base.port!))
            try await client.connect()
            // Two pipelined requests, then one asking to close.
            try await client.send("GET /echo?n=1 HTTP/1.1\r\nHost: x\r\n\r\nGET /echo?n=2 HTTP/1.1\r\nHost: x\r\n\r\n")
            let first = try await client.readResponse()
            let second = try await client.readResponse()
            #expect(first.status == 200)
            #expect(second.status == 200)
            #expect(first.headers["connection"] == "keep-alive")
            #expect(try JSONDecoder().decode(Echo.self, from: first.body).query == ["n": "1"])
            #expect(try JSONDecoder().decode(Echo.self, from: second.body).query == ["n": "2"])

            try await client.send("GET /echo?n=3 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            let third = try await client.readResponse()
            #expect(third.status == 200)
            #expect(third.headers["connection"] == "close")
            #expect(try await client.awaitEOF())
            #expect(await server.acceptedConnectionCount == 1)
        }
    }

    @Test func headOmitsBodyButKeepsConnectionUsable() async throws {
        try await withServer(echoRouter()) { _, base in
            let client = RawClient(port: UInt16(base.port!))
            try await client.connect()
            try await client.send("HEAD /token HTTP/1.1\r\nHost: x\r\n\r\n")
            let head = try await client.readResponseHeadOnly()
            #expect(head.status == 200)
            #expect(head.headers["content-length"] == "4") // what GET would send: "none"

            // Had a body followed the HEAD response, it would corrupt the next status line.
            try await client.send("GET /token HTTP/1.1\r\nHost: x\r\n\r\n")
            let get = try await client.readResponse()
            #expect(get.status == 200)
            #expect(String(decoding: get.body, as: UTF8.self) == "none")
            client.close()
        }
    }

    @Test func oversizedBodyIs413() async throws {
        try await withServer(echoRouter()) { _, base in
            var request = URLRequest(url: base.appending(path: "run/guest"))
            request.httpMethod = "POST"
            request.httpBody = Data(count: HTTPWire.maxBodyBytes + 1)
            let (data, response) = try await makeSession().data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 413)
            #expect(try JSONDecoder().decode(ErrorEnvelope.self, from: data).error.contains("too large"))
        }
    }

    @Test func declaredOversizedBodyIsRejectedBeforeUpload() async throws {
        try await withServer(echoRouter()) { _, base in
            let client = RawClient(port: UInt16(base.port!))
            try await client.connect()
            try await client.send("POST /run/x HTTP/1.1\r\nHost: x\r\nContent-Length: 99999999\r\n\r\n")
            let response = try await client.readResponse()
            #expect(response.status == 413)
            #expect(response.headers["connection"] == "close")
            client.close()
        }
    }

    @Test func chunkedRequestBodyIsRejected() async throws {
        try await withServer(echoRouter()) { _, base in
            let client = RawClient(port: UInt16(base.port!))
            try await client.connect()
            try await client.send("POST /run/x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n")
            let response = try await client.readResponse()
            #expect(response.status == 411)
            #expect(try await client.awaitEOF())
        }
    }

    @Test func oversizedHeaderIs431() async throws {
        try await withServer(echoRouter()) { _, base in
            let client = RawClient(port: UInt16(base.port!))
            try await client.connect()
            let huge = String(repeating: "x", count: HTTPWire.maxHeaderBytes + 10)
            try await client.send("GET /echo HTTP/1.1\r\nHost: x\r\nX-Big: \(huge)\r\n\r\n")
            let response = try await client.readResponse()
            #expect(response.status == 431)
            client.close()
        }
    }

    @Test func malformedRequestLineIs400() async throws {
        try await withServer(echoRouter()) { _, base in
            let client = RawClient(port: UInt16(base.port!))
            try await client.connect()
            try await client.send("NONSENSE\r\n\r\n")
            let response = try await client.readResponse()
            #expect(response.status == 400)
            #expect(try await client.awaitEOF())
        }
    }

    @Test func percentDecodingOfPathAndQuery() async throws {
        try await withServer(echoRouter()) { _, base in
            let url = URL(string: base.absoluteString + "/caf%C3%A9%20bar?q=%E2%9C%93&sp=a+b%2Bc&empty&k%3Dey=v%26")!
            let (data, response) = try await makeSession().data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            let echo = try JSONDecoder().decode(Echo.self, from: data)
            #expect(echo.path == "/café bar")
            #expect(echo.query == ["q": "✓", "sp": "a b+c", "empty": "", "k=ey": "v&"])
        }
    }

    @Test func stopReleasesPortAndClosesIdleConnections() async throws {
        let first = HTTPServer(handler: echoRouter().handler)
        try await first.start()
        let port = await first.port
        #expect(port != 0)

        // Leave an idle keep-alive connection behind.
        let session = makeSession()
        let (_, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/echo")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(await first.activeConnectionCount == 1)

        // While it runs, the port is taken.
        let squatter = HTTPServer(port: port, handler: echoRouter().handler)
        await #expect(throws: (any Error).self) { try await squatter.start() }

        let started = ContinuousClock.now
        await first.stop()
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(await first.activeConnectionCount == 0)
        #expect(await first.port == 0)

        let second = HTTPServer(port: port, handler: echoRouter().handler)
        try await second.start()
        #expect(await second.port == port)
        let (_, again) = try await makeSession().data(from: URL(string: "http://127.0.0.1:\(port)/echo")!)
        #expect((again as? HTTPURLResponse)?.statusCode == 200)
        await second.stop()
    }

    @Test func bonjourOptionDoesNotBreakStartServeStop() async throws {
        // Only plain start/serve/stop is asserted: whether the advertisement is visible to a
        // browser depends on the machine's network and is not this test's business.
        let service = BonjourService(name: "TinyHTTP test", type: "_tinyhttptest._tcp")
        #expect(service == BonjourService(name: "TinyHTTP test", type: "_tinyhttptest._tcp"))

        let server = HTTPServer(bonjour: service, handler: echoRouter().handler)
        try await server.start()
        let port = await server.port
        #expect(port != 0)
        let (data, response) = try await makeSession().data(from: URL(string: "http://127.0.0.1:\(port)/echo")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(!data.isEmpty)
        await server.stop()
        #expect(await server.port == 0)
        #expect(await server.activeConnectionCount == 0)
    }

    @Test func startTwiceThrows() async throws {
        let server = HTTPServer(handler: echoRouter().handler)
        try await server.start()
        await #expect(throws: HTTPServerError.self) { try await server.start() }
        await server.stop()
    }
}

// MARK: - Pure wire helpers

@Suite("HTTPWire")
struct HTTPWireTests {
    @Test func incompleteHeadReturnsNil() throws {
        #expect(try HTTPWire.parseHead(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)) == nil)
    }

    @Test func parsesHeadWithFoldedDuplicatesAndBareLF() throws {
        let head = try #require(try HTTPWire.parseHead(Data("GET /p?q=1 HTTP/1.1\nHost: x\nX-A: 1\nx-a: 2\n\nleftover".utf8)))
        #expect(head.method == "GET")
        #expect(head.target == "/p?q=1")
        #expect(head.version == "HTTP/1.1")
        #expect(head.headers == ["host": "x", "x-a": "1, 2"])
        #expect(head.length == "GET /p?q=1 HTTP/1.1\nHost: x\nX-A: 1\nx-a: 2\n\n".utf8.count)
    }

    @Test func parseTargetDecodesAndSplits() {
        let (path, query) = HTTPWire.parseTarget("/a%2Fb%20c?x=1&y=%7E&z&p=a+b")
        #expect(path == "/a/b c")
        #expect(query == ["x": "1", "y": "~", "z": "", "p": "a b"])
        #expect(HTTPWire.parseTarget("http://host:1/x?y=2").path == "/x")
        #expect(HTTPWire.parseTarget("").path == "/")
    }

    @Test func percentDecodingIsLenient() {
        #expect(HTTPWire.percentDecode("100%", plusAsSpace: false) == "100%")
        #expect(HTTPWire.percentDecode("%zz%4", plusAsSpace: false) == "%zz%4")
        #expect(HTTPWire.percentDecode("a+b", plusAsSpace: false) == "a+b")
        #expect(HTTPWire.percentDecode("a+b", plusAsSpace: true) == "a b")
    }

    @Test func keepAliveRules() {
        #expect(HTTPWire.wantsKeepAlive(version: "HTTP/1.1", headers: [:]))
        #expect(!HTTPWire.wantsKeepAlive(version: "HTTP/1.1", headers: ["connection": "close"]))
        #expect(!HTTPWire.wantsKeepAlive(version: "HTTP/1.1", headers: ["connection": "Upgrade, Close"]))
        #expect(!HTTPWire.wantsKeepAlive(version: "HTTP/1.0", headers: [:]))
        #expect(HTTPWire.wantsKeepAlive(version: "HTTP/1.0", headers: ["connection": "keep-alive"]))
    }

    @Test func httpDateFormat() {
        #expect(HTTPWire.httpDate(Date(timeIntervalSince1970: 0)) == "Thu, 01 Jan 1970 00:00:00 GMT")
        #expect(HTTPWire.httpDate(Date(timeIntervalSince1970: 1_791_749_703)) == "Sun, 11 Oct 2026 20:15:03 GMT")
    }
}
