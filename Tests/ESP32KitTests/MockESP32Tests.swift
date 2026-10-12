import ESP32Kit
import Foundation
import os
import SwitchboardCore
import Testing
import TinyHTTP

@Suite("MockESP32")
struct MockESP32Tests {
    /// The exact `GET /state` document from docs/BRIEF.md, section 5.
    static let briefJSON = #"{ "hdmi": { "dualup": 1, "lg4k": 1, "samsung": 1 }, "usb": { "port": 1, "source": "aten" }, "uptime": 123 }"#

    // MARK: GET /state

    @Test("GET /state serves exactly the brief's JSON shape")
    func stateShape() async throws {
        try await withMock(initialState: briefState(uptime: 123)) { _, url in
            let reply = try await rawRequest("GET", url, path: "state")
            #expect(reply.status == 200)

            // The raw document has the three top-level keys and nothing else.
            let object = try #require(reply.object)
            #expect(Set(object.keys) == ["hdmi", "usb", "uptime"])
            let hdmi = try #require(object["hdmi"] as? [String: Int])
            #expect(hdmi == ["dualup": 1, "lg4k": 1, "samsung": 1])
            let usb = try #require(object["usb"] as? [String: Any])
            #expect(usb["port"] as? Int == 1)
            #expect(usb["source"] as? String == "aten")
            #expect(object["uptime"] as? Int == 123)

            // And it decodes to the same value as the brief's example.
            let served = try JSONDecoder().decode(ControllerState.self, from: reply.body)
            let expected = try JSONDecoder().decode(ControllerState.self, from: Data(Self.briefJSON.utf8))
            #expect(served == expected)
        }
    }

    @Test("the default state is every display on input 1 and USB port 1 from aten")
    func defaultState() async throws {
        let mock = MockESP32()
        let state = await mock.currentState
        #expect(state.hdmi == [.dualup: 1, .lg4k: 1, .samsung: 1])
        #expect(state.usb == .init(port: 1, source: "aten"))
        #expect(state.uptime >= 0)
    }

    @Test("uptime counts seconds from the start date and setState moves it")
    func uptime() async throws {
        let clock = TestClock()
        let mock = MockESP32(now: { clock.now })
        #expect(await mock.currentState.uptime == 0)
        clock.advance(by: 42.9)
        #expect(await mock.currentState.uptime == 42)

        await mock.setState(briefState(uptime: 1000))
        #expect(await mock.currentState.uptime == 1000)
        clock.advance(by: 5)
        #expect(await mock.currentState.uptime == 1005)
    }

    // MARK: HDMI

    @Test("hdmi select and resync set the input and answer with the new state")
    func hdmiSelectAndResync() async throws {
        try await withMock { mock, url in
            let select = try await rawRequest("POST", url, path: "hdmi/lg4k/select", body: #"{"input": 2}"#)
            #expect(select.status == 200)
            let afterSelect = try JSONDecoder().decode(ControllerState.self, from: select.body)
            #expect(afterSelect.hdmi == [.dualup: 1, .lg4k: 2, .samsung: 1])

            let resync = try await rawRequest("POST", url, path: "hdmi/samsung/resync", body: #"{"input":2}"#)
            #expect(resync.status == 200)
            let afterResync = try JSONDecoder().decode(ControllerState.self, from: resync.body)
            #expect(afterResync.hdmi == [.dualup: 1, .lg4k: 2, .samsung: 2])
            #expect(await mock.currentState.hdmi == afterResync.hdmi)
        }
    }

    @Test("an unknown display is 404 with the contract's error body")
    func unknownDisplay() async throws {
        try await withMock { mock, url in
            for action in ["select", "resync"] {
                let reply = try await rawRequest("POST", url, path: "hdmi/projector/\(action)", body: #"{"input":1}"#)
                #expect(reply.status == 404)
                #expect(reply.object as? [String: String] == ["error": "unknown display"])
            }
            #expect(await mock.currentState.hdmi == briefState().hdmi)
        }
    }

    @Test("inputs other than 1 and 2 are 400 and change nothing", arguments: [
        #"{"input": 3}"#,
        #"{"input": 0}"#,
        #"{"input": -1}"#,
        #"{"input": 1.5}"#,
        #"{"input": "1"}"#,
        #"{"input": true}"#,
        #"{"input": null}"#,
        #"{}"#,
        #"not json"#,
        ""
    ])
    func invalidInput(body: String) async throws {
        try await withMock { mock, url in
            for action in ["select", "resync"] {
                let reply = try await rawRequest("POST", url, path: "hdmi/dualup/\(action)", body: body)
                #expect(reply.status == 400)
                #expect(reply.object as? [String: String] == ["error": "invalid input"])
            }
            #expect(await mock.currentState.hdmi == briefState().hdmi)
        }
    }

    @Test("an unknown display wins over a bad body")
    func unknownDisplayBeforeBody() async throws {
        try await withMock { _, url in
            let reply = try await rawRequest("POST", url, path: "hdmi/projector/select", body: "garbage")
            #expect(reply.status == 404)
        }
    }

    // MARK: USB

    @Test("usb select sets the port 1...4 and answers with the new state")
    func usbSelect() async throws {
        try await withMock { mock, url in
            for port in 1...4 {
                let reply = try await rawRequest("POST", url, path: "usb/select", body: #"{"port": \#(port)}"#)
                #expect(reply.status == 200)
                let state = try JSONDecoder().decode(ControllerState.self, from: reply.body)
                #expect(state.usb == .init(port: port, source: "aten"))
            }
            #expect(await mock.currentState.usb.port == 4)
        }
    }

    @Test("usb ports outside 1...4 and malformed bodies are 400", arguments: [
        #"{"port": 0}"#, #"{"port": 5}"#, #"{"port": "2"}"#, #"{"input": 2}"#, #"{}"#, "nope",
    ])
    func usbInvalid(body: String) async throws {
        try await withMock { mock, url in
            let reply = try await rawRequest("POST", url, path: "usb/select", body: body)
            #expect(reply.status == 400)
            #expect(reply.object as? [String: String] == ["error": "invalid port"])
            #expect(await mock.currentState.usb.port == 1)
        }
    }

    // MARK: Routing, hooks, log

    @Test("wrong method and unknown path use the TinyHTTP router's answers")
    func routing() async throws {
        try await withMock { _, url in
            let getUSB = try await rawRequest("GET", url, path: "usb/select")
            let postState = try await rawRequest("POST", url, path: "state")
            let unknown = try await rawRequest("GET", url, path: "nothing")
            #expect(getUSB.status == 405)
            #expect(postState.status == 405)
            #expect(unknown.status == 404)
        }
    }

    @Test("failNextRequest answers the next request with that status, once, and logs it")
    func failNextRequest() async throws {
        try await withMock { mock, url in
            await mock.failNextRequest(status: 503)
            let failed = try await rawRequest("POST", url, path: "usb/select", body: #"{"port": 3}"#)
            #expect(failed.status == 503)
            #expect(failed.object as? [String: String] == ["error": "injected failure"])
            #expect(await mock.currentState.usb.port == 1, "a failed request must not change the state")

            let fine = try await rawRequest("GET", url, path: "state")
            #expect(fine.status == 200)

            await mock.failNextRequest(status: 500)
            await mock.failNextRequest(status: 404)
            #expect(try await rawRequest("GET", url, path: "state").status == 500)
            #expect(try await rawRequest("GET", url, path: "state").status == 404)
            #expect(try await rawRequest("GET", url, path: "state").status == 200)
        }
    }

    @Test("requestLog records method, path, body and status in order")
    func requestLog() async throws {
        try await withMock { mock, url in
            _ = try await rawRequest("GET", url, path: "state")
            _ = try await rawRequest("POST", url, path: "hdmi/dualup/select", body: #"{"input":2}"#)
            _ = try await rawRequest("POST", url, path: "usb/select", body: #"{"port":9}"#)

            let log = await mock.requestLog
            #expect(log.map(\.method) == ["GET", "POST", "POST"])
            #expect(log.map(\.path) == ["/state", "/hdmi/dualup/select", "/usb/select"])
            #expect(log.map(\.status) == [200, 200, 400])
            #expect(log[1].body == #"{"input":2}"#)
            #expect(log[0].body.isEmpty)
        }
    }

    @Test("onRequest is called for every request")
    func onRequestObserver() async throws {
        let seen = Seen()
        let mock = MockESP32(onRequest: { seen.add("\($0.method) \($0.path) \($0.status)") })
        try await mock.start()
        let url = try #require(await mock.url)
        _ = try await rawRequest("GET", url, path: "state")
        _ = try await rawRequest("POST", url, path: "usb/select", body: #"{"port":2}"#)
        await mock.stop()
        #expect(seen.all == ["GET /state 200", "POST /usb/select 200"])
    }

    @Test("pulseDelay is spent on a select that changes the input, never on resync")
    func pulseDelay() async throws {
        try await withMock(pulseDelay: .milliseconds(300)) { _, url in
            let clock = ContinuousClock()

            var started = clock.now
            _ = try await rawRequest("POST", url, path: "hdmi/dualup/select", body: #"{"input":2}"#)
            #expect(clock.now - started >= .milliseconds(290))

            started = clock.now
            _ = try await rawRequest("POST", url, path: "hdmi/dualup/select", body: #"{"input":2}"#)
            #expect(clock.now - started < .milliseconds(250), "already on input 2: no pulse needed")

            started = clock.now
            _ = try await rawRequest("POST", url, path: "hdmi/dualup/resync", body: #"{"input":1}"#)
            #expect(clock.now - started < .milliseconds(250), "resync never pulses")
        }
    }

    // MARK: Lifecycle

    @Test("a stopped mock has no port or url; restarting reuses the port and keeps the state")
    func restart() async throws {
        let mock = MockESP32()
        #expect(await mock.url == nil)
        #expect(await mock.port == 0)

        try await mock.start()
        let port = await mock.port
        #expect(port != 0)
        _ = try await rawRequest("POST", try #require(await mock.url), path: "usb/select", body: #"{"port":4}"#)
        await mock.stop()
        #expect(await mock.port == 0)
        #expect(await mock.url == nil)

        try await mock.start()
        #expect(await mock.port == port)
        let reply = try await rawRequest("GET", try #require(await mock.url), path: "state")
        #expect(try JSONDecoder().decode(ControllerState.self, from: reply.body).usb.port == 4)
        await mock.stop()
    }

    @Test("starting twice throws")
    func startTwice() async throws {
        let mock = MockESP32()
        try await mock.start()
        await #expect(throws: HTTPServerError.self) { try await mock.start() }
        await mock.stop()
    }

    @Test("the bonjour option starts, serves and stops like a plain mock")
    func bonjourOption() async throws {
        // No assertion on mDNS visibility: that depends on the machine's network.
        let mock = MockESP32(bonjour: true, bonjourName: "Switchboard Mock (test)")
        try await mock.start()
        let reply = try await rawRequest("GET", try #require(await mock.url), path: "state")
        #expect(reply.status == 200)
        await mock.stop()
    }

    // MARK: GET /events

    @Test("events: state on connect, state on change, keepalive comments, in SSE wire format")
    func eventsWireFormat() async throws {
        try await withMock(keepaliveInterval: .milliseconds(60)) { mock, url in
            try await withTimeout(.seconds(5)) {
                let (bytes, response) = try await makeSession().bytes(from: url.appending(path: "events"))
                let http = try #require(response as? HTTPURLResponse)
                #expect(http.statusCode == 200)
                #expect(http.value(forHTTPHeaderField: "Content-Type") == "text/event-stream")

                var lines = bytes.lines.makeAsyncIterator()

                // 1. The state on connect: `event: state`, one `data:` line, blank line.
                #expect(try await lines.next() == "event: state")
                let data = try #require(try await lines.next())
                #expect(data.hasPrefix("data: {"))
                let connected = try JSONDecoder().decode(ControllerState.self, from: Data(data.dropFirst("data: ".count).utf8))
                #expect(connected == (await mock.currentState))

                // 2. A change is pushed. (Lines may be interleaved with keepalives, which are
                //    comment lines; skip them.)
                _ = try await rawRequest("POST", url, path: "usb/select", body: #"{"port":3}"#)
                var sawChange = false
                var sawKeepalive = false
                while let line = try await lines.next() {
                    if line == ": keepalive" { sawKeepalive = true }
                    if line.hasPrefix("data: "),
                       let state = try? JSONDecoder().decode(ControllerState.self, from: Data(line.dropFirst("data: ".count).utf8)),
                       state.usb.port == 3 {
                        sawChange = true
                    }
                    if sawChange && sawKeepalive { break }
                }
                #expect(sawChange)
                #expect(sawKeepalive)
            }
        }
    }

    @Test("events fan out to every open connection and the subscriber count follows disconnects")
    func eventsFanOut() async throws {
        try await withMock { mock, url in
            try await withTimeout(.seconds(8)) {
                func listen() -> Task<ControllerState?, any Error> {
                    Task {
                        let (bytes, _) = try await makeSession().bytes(from: url.appending(path: "events"))
                        for try await event in SSEParser.events(from: bytes) {
                            let state = try JSONDecoder().decode(ControllerState.self, from: Data(event.data.utf8))
                            if state.hdmi[.samsung] == 2 { return state }
                        }
                        return nil
                    }
                }
                let a = listen()
                let b = listen()
                #expect(await eventually { await mock.eventSubscriberCount == 2 })

                await mock.setState(ControllerState(hdmi: [.dualup: 1, .lg4k: 1, .samsung: 2], usb: .init(port: 1, source: "aten"), uptime: 5))
                let (first, second) = try await (a.value, b.value)
                #expect(first?.hdmi[.samsung] == 2)
                #expect(second?.hdmi[.samsung] == 2)

                #expect(await eventually { await mock.eventSubscriberCount == 0 }, "listeners returned, so their connections closed")
            }
        }
    }
}

/// Collects strings from a `@Sendable` callback.
private final class Seen: Sendable {
    private let items = OSAllocatedUnfairLock<[String]>(initialState: [])

    func add(_ item: String) { items.withLock { $0.append(item) } }
    var all: [String] { items.withLock { $0 } }
}
