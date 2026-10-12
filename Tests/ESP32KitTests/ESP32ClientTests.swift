import ESP32Kit
import Foundation
import SwitchboardCore
import Testing
import TinyHTTP

@Suite("ESP32Client")
struct ESP32ClientTests {
    // MARK: Round trips through the mock

    @Test("state decodes the mock's state")
    func state() async throws {
        try await withMock(initialState: briefState(uptime: 77)) { _, url in
            let state = try await ESP32Client(baseURL: url).state()
            #expect(state == briefState(uptime: 77))
        }
    }

    @Test("selectHDMI, resyncHDMI and selectUSB send the contract's requests and return the new state")
    func commands() async throws {
        try await withMock { mock, url in
            let client = ESP32Client(baseURL: url)

            let selected = try await client.selectHDMI(.lg4k, input: 2)
            #expect(selected.hdmi == [.dualup: 1, .lg4k: 2, .samsung: 1])

            let resynced = try await client.resyncHDMI(.samsung, input: 2)
            #expect(resynced.hdmi == [.dualup: 1, .lg4k: 2, .samsung: 2])

            let usb = try await client.selectUSB(port: 3)
            #expect(usb.usb == .init(port: 3, source: "aten"))

            #expect(try await client.state() == (await mock.currentState))

            // What went over the wire: method, path, JSON body.
            let log = await mock.requestLog.map { "\($0.method) \($0.path) \($0.body)" }
            #expect(log == [
                #"POST /hdmi/lg4k/select {"input":2}"#,
                #"POST /hdmi/samsung/resync {"input":2}"#,
                #"POST /usb/select {"port":3}"#,
                "GET /state ",
            ])
        }
    }

    @Test("every display id is addressed by its raw value", arguments: DisplayID.allCases)
    func displayPaths(display: DisplayID) async throws {
        try await withMock { mock, url in
            _ = try await ESP32Client(baseURL: url).resyncHDMI(display, input: 2)
            #expect(await mock.requestLog.map(\.path) == ["/hdmi/\(display.rawValue)/resync"])
            #expect(await mock.currentState.hdmi[display] == 2)
        }
    }

    @Test("a base URL with a path prefix keeps it")
    func basePathPrefix() async throws {
        var router = Router()
        router.get("/switchboard/state") { _ in .json(briefState()) }
        let server = HTTPServer(handler: router.handler)
        try await server.start()
        let port = await server.port
        let client = ESP32Client(baseURL: URL(string: "http://127.0.0.1:\(port)/switchboard")!)
        #expect(try await client.state() == briefState())
        await server.stop()
    }

    // MARK: Errors

    @Test("validation errors surface as httpStatus with the status and the body")
    func validationErrors() async throws {
        try await withMock { mock, url in
            let client = ESP32Client(baseURL: url)

            let badInput = await controllerError { try await client.selectHDMI(.dualup, input: 3) }
            guard case .httpStatus(400, let body)? = badInput else {
                Issue.record("expected httpStatus(400, …), got \(String(describing: badInput))")
                return
            }
            #expect(body.contains("invalid input"))

            let badPort = await controllerError { try await client.selectUSB(port: 5) }
            guard case .httpStatus(400, _)? = badPort else {
                Issue.record("expected httpStatus(400, …), got \(String(describing: badPort))")
                return
            }

            // The typed client cannot name an unknown display, so have the mock say 404.
            await mock.failNextRequest(status: 404)
            let notFound = await controllerError { try await client.resyncHDMI(.samsung, input: 1) }
            guard case .httpStatus(404, let notFoundBody)? = notFound else {
                Issue.record("expected httpStatus(404, …), got \(String(describing: notFound))")
                return
            }
            #expect(notFoundBody.contains("injected failure"))

            #expect(await mock.currentState.hdmi == briefState().hdmi, "rejected requests change nothing")
        }
    }

    @Test("a port nobody listens on is unreachable, naming host and port")
    func unreachable() async throws {
        let mock = MockESP32()
        try await mock.start()
        let port = await mock.port
        await mock.stop()

        let client = ESP32Client(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        let error = await controllerError { try await client.state() }
        guard case .unreachable(let url, let underlying)? = error else {
            Issue.record("expected unreachable, got \(String(describing: error))")
            return
        }
        #expect(url.port == Int(port))
        #expect(!underlying.isEmpty)
        #expect(error?.description.contains("127.0.0.1:\(port)") == true)
    }

    @Test("a controller that accepts and never answers times out at the client's deadline")
    func timeout() async throws {
        let server = HTTPServer { _ in
            try? await Task.sleep(for: .seconds(10))
            return .empty()
        }
        try await server.start()
        let port = await server.port

        let client = ESP32Client(baseURL: URL(string: "http://127.0.0.1:\(port)")!, timeout: .milliseconds(300))
        let clock = ContinuousClock()
        let started = clock.now
        let error = await controllerError { try await client.state() }
        #expect(error == .timeout)
        #expect(clock.now - started < .seconds(3))
        #expect(error?.description == "controller did not answer in time")
        await server.stop()
    }

    @Test("a reply that is not a state object is invalidResponse", arguments: [
        #"{"nope": 1}"#,
        #"{"hdmi": {"dualup": 1}, "usb": {"port": "x", "source": "aten"}, "uptime": 1}"#,
        "<html>hello</html>",
        "",
    ])
    func invalidResponse(body: String) async throws {
        let server = HTTPServer { _ in
            HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
        }
        try await server.start()
        let port = await server.port
        let client = ESP32Client(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        let error = await controllerError { try await client.state() }
        guard case .invalidResponse(let detail)? = error else {
            Issue.record("expected invalidResponse, got \(String(describing: error))")
            await server.stop()
            return
        }
        #expect(!detail.isEmpty)
        await server.stop()
    }

    @Test("errors read well")
    func descriptions() {
        let url = URL(string: "http://esp32.local:80")!
        #expect(ControllerError.unreachable(url, underlying: "Could not connect").description
            == "controller unreachable at esp32.local:80: Could not connect")
        #expect(ControllerError.httpStatus(400, body: #"{"error":"invalid input"}"#).description
            == #"controller replied HTTP 400 (bad request): {"error":"invalid input"}"#)
        #expect(ControllerError.httpStatus(503, body: "").description == "controller replied HTTP 503 (service unavailable)")
        #expect(ControllerError.invalidResponse("no uptime").description == "controller sent an invalid response: no uptime")
        #expect(ControllerError.timeout.errorDescription == "controller did not answer in time")
    }

    @Test("cancelling a request throws CancellationError, not a controller error")
    func cancellation() async throws {
        let server = HTTPServer { _ in
            try? await Task.sleep(for: .seconds(10))
            return .empty()
        }
        try await server.start()
        let port = await server.port
        let client = ESP32Client(baseURL: URL(string: "http://127.0.0.1:\(port)")!, timeout: .seconds(30))

        let task = Task { try await client.state() }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await withTimeout(.seconds(3)) { try await task.value }
            Issue.record("expected cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
        await server.stop()
    }

    // MARK: events()

    @Test("events yields the current state, then each change")
    func events() async throws {
        try await withMock { mock, url in
            let client = ESP32Client(baseURL: url)
            try await withTimeout(.seconds(5)) {
                var iterator = client.events().makeAsyncIterator()

                let first = await iterator.next()
                #expect(first == briefState(uptime: 0))

                _ = try await client.selectUSB(port: 2)
                let second = await iterator.next()
                #expect(second?.usb.port == 2)
                #expect(second?.hdmi == first?.hdmi)

                _ = try await client.resyncHDMI(.samsung, input: 2)
                let third = await iterator.next()
                #expect(third?.hdmi[.samsung] == 2)
                #expect(third?.usb.port == 2)
            }
        }
    }

    @Test("events reconnects with backoff after the controller goes away and comes back")
    func eventsReconnect() async throws {
        let mock = MockESP32()
        try await mock.start()
        let url = try #require(await mock.url)
        let client = ESP32Client(baseURL: url, eventsBackoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100)))

        try await withTimeout(.seconds(8)) {
            var iterator = client.events().makeAsyncIterator()
            let before = await iterator.next()
            #expect(before?.usb.port == 1)

            // The controller drops off the network, changes while it is away, and returns.
            await mock.stop()
            await mock.setState(ControllerState(hdmi: [.dualup: 2, .lg4k: 1, .samsung: 1], usb: .init(port: 4, source: "aten"), uptime: 0))
            try await Task.sleep(for: .milliseconds(150))  // a few failed attempts
            try await mock.start()

            let after = await iterator.next()
            #expect(after?.usb.port == 4)
            #expect(after?.hdmi[.dualup] == 2)
        }
        await mock.stop()
    }

    @Test("events starts delivering once a controller that was down at subscribe time appears")
    func eventsBeforeControllerExists() async throws {
        // Reserve a port, then free it so the first connection attempts are refused.
        let mock = MockESP32()
        try await mock.start()
        let url = try #require(await mock.url)
        await mock.stop()

        let client = ESP32Client(baseURL: url, eventsBackoff: .init(initial: .milliseconds(20), maximum: .milliseconds(100)))
        try await withTimeout(.seconds(8)) {
            var iterator = client.events().makeAsyncIterator()
            try await Task.sleep(for: .milliseconds(100))
            try await mock.start()
            let first = await iterator.next()
            #expect(first?.usb.port == 1)
        }
        await mock.stop()
    }

    @Test("dropping the stream closes the connection")
    func eventsCancellation() async throws {
        try await withMock { mock, url in
            let client = ESP32Client(baseURL: url)
            let consumer = Task {
                for await _ in client.events() {}
            }
            #expect(await eventually { await mock.eventSubscriberCount == 1 })

            consumer.cancel()
            #expect(await eventually { await mock.eventSubscriberCount == 0 })
            await consumer.value
        }
    }

    @Test("events ignores payloads that are not states and the event name")
    func eventsIgnoresNoise() async throws {
        var router = Router()
        router.get("/events") { _ in
            .eventStream { emitter in
                try? await emitter.comment("hello")
                try? await emitter.send(event: "message", data: "not json")
                try? await emitter.send(data: #"{"unrelated": true}"#)
                // An unnamed event, as a firmware might send it.
                try? await emitter.send(data: #"{"hdmi":{"dualup":2,"lg4k":1,"samsung":1},"usb":{"port":3,"source":"aten"},"uptime":9}"#)
                try? await Task.sleep(for: .seconds(5))
            }
        }
        let server = HTTPServer(handler: router.handler)
        try await server.start()
        let port = await server.port
        let client = ESP32Client(baseURL: URL(string: "http://127.0.0.1:\(port)")!)

        try await withTimeout(.seconds(5)) {
            var iterator = client.events().makeAsyncIterator()
            let state = await iterator.next()
            #expect(state == ControllerState(hdmi: [.dualup: 2, .lg4k: 1, .samsung: 1], usb: .init(port: 3, source: "aten"), uptime: 9))
        }
        await server.stop()
    }
}
