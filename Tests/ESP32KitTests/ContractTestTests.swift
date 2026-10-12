import ESP32Kit
import Foundation
import SwitchboardCore
import Testing
import TinyHTTP

@Suite("ContractTest")
struct ContractTestTests {
    static let names = [
        "GET /state returns the state object",
        "POST /hdmi/dualup/resync sets the assumed input",
        "POST /hdmi/lg4k/select changes the input",
        "POST /usb/select changes the port",
        "errors: unknown display is 404, invalid input is 400",
        "GET /events sends the state on connect and on change",
    ]

    @Test("every check passes against MockESP32, and the mock is left as it was")
    func passesAgainstMock() async throws {
        try await withMock { mock, url in
            let before = await mock.currentState
            let results = try await withTimeout(.seconds(20)) { await ContractTest(baseURL: url).run() }

            #expect(results.map(\.name) == Self.names)
            for check in results {
                #expect(check.passed, "\(check.name): \(check.detail)")
                #expect(!check.detail.isEmpty)
            }

            let after = await mock.currentState
            #expect(after.hdmi == before.hdmi)
            #expect(after.usb == before.usb)
            #expect(await eventually { await mock.eventSubscriberCount == 0 }, "the events check leaves no connection behind")
        }
    }

    @Test("it also passes when the mock starts away from the defaults")
    func passesFromOtherStartingPoint() async throws {
        let start = ControllerState(hdmi: [.dualup: 2, .lg4k: 2, .samsung: 1], usb: .init(port: 4, source: "aten"), uptime: 9)
        try await withMock(initialState: start) { mock, url in
            let results = try await withTimeout(.seconds(20)) { await ContractTest(baseURL: url).run() }
            let failed = results.filter { !$0.passed }
            #expect(failed.isEmpty, "\(failed)")
            let after = await mock.currentState
            #expect(after.hdmi == start.hdmi)
            #expect(after.usb == start.usb)
        }
    }

    @Test("a request the controller fails fails that check, with the status in the detail; the others still pass")
    func failedRequestFailsOneCheck() async throws {
        try await withMock { mock, url in
            // The first request of the run is check 1's GET /state.
            await mock.failNextRequest(status: 500)
            let results = try await withTimeout(.seconds(20)) { await ContractTest(baseURL: url).run() }

            #expect(results.map(\.name) == Self.names)
            #expect(results[0].passed == false)
            #expect(results[0].detail.contains("500"), "detail was: \(results[0].detail)")
            #expect(results[0].detail.contains("GET /state"))
            for check in results.dropFirst() {
                #expect(check.passed, "\(check.name): \(check.detail)")
            }
        }
    }

    @Test("a check that fails after the controller changed still puts the state back")
    func restoresAfterFailure() async throws {
        try await withMock { mock, mockURL in
            // A controller whose lg4k select works but whose reply claims nothing changed.
            try await withFront(to: mockURL, overrides: { router, forward in
                router.post("/hdmi/lg4k/select") { request in
                    _ = await forward("POST", "hdmi/lg4k/select", request.body)
                    return .json(briefState())
                }
            }) { frontURL in
                let results = try await withTimeout(.seconds(20)) { await ContractTest(baseURL: frontURL).run() }

                let lg4k = try #require(results.first { $0.name == Self.names[2] })
                #expect(lg4k.passed == false)
                #expect(lg4k.detail.contains("reply has hdmi.lg4k = 1, expected 2"), "detail was: \(lg4k.detail)")
                // The front serves no /events, so that last check fails for its own reason.
                for check in results where check.name != Self.names[2] && check.name != Self.names[5] {
                    #expect(check.passed, "\(check.name): \(check.detail)")
                }
                #expect(await mock.currentState.hdmi == briefState().hdmi, "the select was undone")
            }
        }
    }

    @Test("a controller whose state lacks a display fails check 1 and names it")
    func missingDisplay() async throws {
        try await withMock { mock, url in
            await mock.setState(ControllerState(hdmi: [.dualup: 1, .lg4k: 1], usb: .init(port: 1, source: "aten"), uptime: 0))
            let results = try await withTimeout(.seconds(20)) { await ContractTest(baseURL: url).run() }
            #expect(results[0].passed == false)
            #expect(results[0].detail.contains("samsung"), "detail was: \(results[0].detail)")
        }
    }

    @Test("out-of-range values in the state fail check 1")
    func outOfRange() async throws {
        let cases: [(ControllerState, String)] = [
            (ControllerState(hdmi: [.dualup: 3, .lg4k: 1, .samsung: 1], usb: .init(port: 1, source: "aten"), uptime: 1), "hdmi.dualup"),
            (ControllerState(hdmi: [.dualup: 1, .lg4k: 1, .samsung: 1], usb: .init(port: 7, source: "aten"), uptime: 1), "usb.port"),
            (ControllerState(hdmi: [.dualup: 1, .lg4k: 1, .samsung: 1], usb: .init(port: 1, source: ""), uptime: 1), "usb.source"),
        ]
        for (state, mention) in cases {
            try await withMock(initialState: state) { _, url in
                let results = try await withTimeout(.seconds(20)) { await ContractTest(baseURL: url).run() }
                #expect(results[0].passed == false)
                #expect(results[0].detail.contains(mention), "detail was: \(results[0].detail)")
            }
        }
    }

    @Test("a controller that accepts invalid input fails the validation check")
    func lenientController() async throws {
        // A stand-in that answers 200 to everything on the POST routes.
        var router = Router()
        let state = briefState()
        router.get("/state") { _ in .json(state) }
        router.post("/hdmi/:display/select") { _, _ in .json(state) }
        router.post("/hdmi/:display/resync") { _, _ in .json(state) }
        router.post("/usb/select") { _ in .json(state) }
        let server = HTTPServer(handler: router.handler)
        try await server.start()
        let port = await server.port

        let results = try await withTimeout(.seconds(20)) {
            await ContractTest(baseURL: URL(string: "http://127.0.0.1:\(port)")!).run()
        }
        let validation = try #require(results.first { $0.name == Self.names[4] })
        #expect(validation.passed == false)
        #expect(validation.detail.contains("expected 404, got 200"), "detail was: \(validation.detail)")
        await server.stop()
    }

    @Test("a dead address fails every check with a reason and returns promptly")
    func unreachable() async throws {
        let mock = MockESP32()
        try await mock.start()
        let url = try #require(await mock.url)
        await mock.stop()

        let started = ContinuousClock.now
        let results = try await withTimeout(.seconds(20)) { await ContractTest(baseURL: url).run() }
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(results.count == 6)
        for check in results {
            #expect(check.passed == false)
            #expect(!check.detail.isEmpty)
        }
        #expect(results[0].detail.contains("unreachable"), "detail was: \(results[0].detail)")
    }

    @Test("a controller with no event stream fails only the events check")
    func noEvents() async throws {
        try await withMock { _, mockURL in
            try await withFront(to: mockURL, overrides: { _, _ in }) { frontURL in
                let results = try await withTimeout(.seconds(20)) { await ContractTest(baseURL: frontURL).run() }
                let others = results.dropLast().filter { !$0.passed }
                #expect(others.isEmpty, "\(others)")
                #expect(results.last?.passed == false)
                #expect(results.last?.detail.contains("404") == true, "detail was: \(results.last?.detail ?? "")")
            }
        }
    }
}

/// Forwards one request to the real mock.
private typealias Forward = @Sendable (_ method: String, _ path: String, _ body: Data) async -> HTTPResponse

/// Serves a front for the mock at `mockURL` that proxies `/state` and the POST routes (not
/// `/events`), after the `overrides` routes, which win because routes match in order.
private func withFront<T>(
    to mockURL: URL,
    overrides: (inout Router, @escaping Forward) -> Void,
    _ body: (URL) async throws -> T
) async throws -> T {
    let forward: Forward = { method, path, body in
        var request = URLRequest(url: mockURL.appending(path: path))
        request.httpMethod = method
        if !body.isEmpty { request.httpBody = body }
        guard let (data, response) = try? await makeSession().data(for: request),
              let http = response as? HTTPURLResponse
        else { return .error("proxy failed", status: 502) }
        return HTTPResponse(status: http.statusCode, headers: ["Content-Type": "application/json"], body: data)
    }

    var router = Router()
    overrides(&router, forward)
    router.get("/state") { _ in await forward("GET", "state", Data()) }
    router.post("/hdmi/:display/select") { request, params in
        await forward("POST", "hdmi/\(params["display"] ?? "")/select", request.body)
    }
    router.post("/hdmi/:display/resync") { request, params in
        await forward("POST", "hdmi/\(params["display"] ?? "")/resync", request.body)
    }
    router.post("/usb/select") { request in await forward("POST", "usb/select", request.body) }

    let front = HTTPServer(handler: router.handler)
    try await front.start()
    let port = await front.port
    do {
        let result = try await body(URL(string: "http://127.0.0.1:\(port)")!)
        await front.stop()
        return result
    } catch {
        await front.stop()
        throw error
    }
}
