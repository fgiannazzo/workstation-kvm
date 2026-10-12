import Actions
import Foundation
import LocalAPI
import StateStore
import SwitchboardCore
import Testing
import TinyHTTP

@MainActor
@Suite("LocalAPIClient")
struct LocalAPIClientTests {
    @Test("health works without a token and says what the server says")
    func health() async throws {
        try await withAPI(version: "1.2.3") { api in
            let client = LocalAPIClient(baseURL: api.baseURL, token: nil, session: api.session)
            let health = try await client.health()
            #expect(health == HealthResponse(ok: true, name: "Switchboard", version: "1.2.3"))
        }
    }

    @Test("state, actions and macros round-trip against the server")
    func reads() async throws {
        try await withAPI { api in
            api.store.applyMonitor(pbp: .on, mainInput: .hdmi2, reachable: true)
            api.store.apply(ControllerState(hdmi: [.lg4k: 2], usb: .init(port: 3, source: "aten"), uptime: 1))
            let client = api.client()

            let state = try await client.state()
            #expect(state == api.store.state)
            #expect(state.updatedAt == fixedNow, "milliseconds survive the round trip")

            let actions = try await client.actions()
            #expect(actions == ActionList(actions: api.runtime.registry.descriptors))

            let macros = try await client.macros()
            #expect(macros == MacroFile(macros: try await api.runtime.macros.macros()))
        }
    }

    @Test("run sends the parameters and returns the handle; the events carry the run")
    func run() async throws {
        try await withAPI { api in
            let client = api.client()

            // What `switchboardctl run` does: subscribe, wait for the connect-time state, start the run.
            let outcome: (initial: SwitchboardState, handle: RunHandle, runs: [RunEvent], sawPort3: Bool) = try await withTimeout {
                var initial: SwitchboardState?
                var handle: RunHandle?
                var runs: [RunEvent] = []
                var sawPort3 = false
                for try await event in client.events() {
                    switch event {
                    case .state(let state):
                        if initial == nil {
                            initial = state
                            handle = try await client.run(id: "usb.select", parameters: ["port": 3])
                        }
                        if state.usbPort == 3 { sawPort3 = true }
                    case .run(let run):
                        runs.append(run)
                    }
                    if runs.last?.isTerminal == true, sawPort3 { break }
                }
                guard let initial, let handle else { throw TimeoutError() }
                return (initial, handle, runs, sawPort3)
            }

            #expect(outcome.initial.usbPort == nil)
            #expect(outcome.handle.id == "usb.select")
            #expect(outcome.handle.kind == .action)
            #expect(outcome.runs.map(\.status) == [.started, .step, .finished])
            #expect(outcome.runs.allSatisfy { $0.runId == outcome.handle.runId })
            #expect(outcome.sawPort3)
            #expect(await api.controller.calls == ["selectUSB(3)"])
        }
    }

    @Test("run of a macro needs no parameters")
    func runMacro() async throws {
        try await withAPI { api in
            let handle = try await api.client().run(id: "solo")
            #expect(handle.kind == .macro)
            let end = await api.runtime.runner.wait(handle)
            #expect(end.status == .finished)
        }
    }

    @Test("a wrong or missing token is LocalAPIError.unauthorized on every authenticated call")
    func unauthorized() async throws {
        try await withAPI { api in
            for client in [api.client(token: "wrong"), LocalAPIClient(baseURL: api.baseURL, token: nil, session: api.session)] {
                await #expect(throws: LocalAPIError.unauthorized) { _ = try await client.state() }
                await #expect(throws: LocalAPIError.unauthorized) { _ = try await client.actions() }
                await #expect(throws: LocalAPIError.unauthorized) { _ = try await client.macros() }
                await #expect(throws: LocalAPIError.unauthorized) { _ = try await client.run(id: "solo") }
                await #expect(throws: LocalAPIError.unauthorized) {
                    for try await _ in client.events() {}
                }
            }
            #expect(await api.runtime.runner.activity.started == 0)
        }
    }

    @Test("the server's refusals come back as .status with the decoded error body")
    func refusals() async throws {
        try await withAPI(holdDelays: true) { api in
            let client = api.client()

            do {
                _ = try await client.run(id: "nope")
                Issue.record("expected a 404")
            } catch let error as LocalAPIError {
                guard case .status(404, _) = error else { Issue.record("expected 404, got \(error)"); return }
                #expect(error.errorBody == APIErrorBody(error: "unknown id", id: "nope"))
                #expect("\(error)".contains("unknown id"))
            }

            do {
                _ = try await client.run(id: "usb.select")
                Issue.record("expected a 400")
            } catch let error as LocalAPIError {
                guard case .status(400, _) = error else { Issue.record("expected 400, got \(error)"); return }
                #expect(error.errorBody == APIErrorBody(error: "missing parameter", parameter: "port"))
            }

            let running = try await client.run(id: "delay", parameters: ["ms": 5000])
            do {
                _ = try await client.run(id: "usb.select", parameters: ["port": 2])
                Issue.record("expected a 409")
            } catch let error as LocalAPIError {
                guard case .status(409, _) = error else { Issue.record("expected 409, got \(error)"); return }
                #expect(error.errorBody == APIErrorBody(error: "busy", runId: running.runId))
            }
        }
    }

    @Test("a server that is not there is .unreachable")
    func unreachable() async throws {
        try await withAPI { api in
            let client = api.client()
            await api.server.stop()
            do {
                _ = try await client.health()
                Issue.record("expected the connection to fail")
            } catch let error as LocalAPIError {
                #expect(error.isUnreachable)
                #expect("\(error)".contains("cannot reach the Switchboard API"))
            }
            do {
                for try await _ in client.events() {}
                Issue.record("expected the connection to fail")
            } catch let error as LocalAPIError {
                #expect(error.isUnreachable)
            }
        }
    }

    @Test("a server that does not speak the contract is .invalidResponse")
    func invalidResponse() async throws {
        var router = Router()
        router.get("/state") { _ in .json(["pbp": 5]) }
        router.get("/health") { _ in .text("not json") }
        let server = HTTPServer(port: 0, handler: router.handler)
        try await server.start()
        let port = await server.port
        let client = LocalAPIClient(baseURL: LocalAPIClient.baseURL(port: Int(port)), token: "t")
        do {
            _ = try await client.state()
            Issue.record("expected an invalid response")
        } catch let error as LocalAPIError {
            guard case .invalidResponse = error else { Issue.record("expected invalidResponse, got \(error)"); return }
        }
        do {
            _ = try await client.health()
            Issue.record("expected an invalid response")
        } catch let error as LocalAPIError {
            guard case .invalidResponse = error else { Issue.record("expected invalidResponse, got \(error)"); return }
        }
        await server.stop()
    }

    @Test("events: unknown event names are ignored, and a stream the server closes ends the sequence")
    func eventsEdgeCases() async throws {
        var router = Router()
        router.get("/events") { _ in
            .eventStream { emitter in
                try? await emitter.send(event: "hello", data: "{}")
                try? await emitter.send(event: "state", data: #"{"pbp":"on","usbPort":null,"updatedAt":"2026-10-11T20:15:03.120Z"}"#)
                try? await emitter.send(event: "run", data: #"{"runId":"r","id":"x","kind":"action","status":"started","step":0,"stepCount":1,"message":""}"#)
            }
        }
        let server = HTTPServer(port: 0, handler: router.handler)
        try await server.start()
        let client = LocalAPIClient(baseURL: LocalAPIClient.baseURL(port: Int(await server.port)), token: "t")

        let collected = try await withTimeout {
            var events: [APIEvent] = []
            for try await event in client.events() { events.append(event) }
            return events
        }
        #expect(collected.count == 2)
        guard case .state(let state) = collected[0], case .run(let run) = collected[1] else {
            Issue.record("unexpected events \(collected)")
            await server.stop()
            return
        }
        // Missing fields decode to their defaults; unknown ones would be ignored.
        #expect(state.pbp == .on)
        #expect(state.updatedAt == fixedNow)
        #expect(run.status == .started)
        await server.stop()
    }

    @Test("events: a state event that is not a state ends the stream with .invalidResponse")
    func eventsGarbage() async throws {
        var router = Router()
        router.get("/events") { _ in
            .eventStream { emitter in try? await emitter.send(event: "state", data: #"{"pbp":"sideways"}"#) }
        }
        let server = HTTPServer(port: 0, handler: router.handler)
        try await server.start()
        let client = LocalAPIClient(baseURL: LocalAPIClient.baseURL(port: Int(await server.port)), token: "t")
        do {
            for try await _ in client.events() {}
            Issue.record("expected the stream to fail")
        } catch let error as LocalAPIError {
            guard case .invalidResponse = error else { Issue.record("expected invalidResponse, got \(error)"); return }
        }
        await server.stop()
    }

    @Test("stopping the iteration closes the connection")
    func eventsCancellation() async throws {
        try await withAPI { api in
            let client = api.client()
            do {
                var count = 0
                for try await _ in client.events() {
                    count += 1
                    break
                }
                #expect(count == 1)
            }
            await eventually(.seconds(5), "the server still holds the connection") {
                let runs = await api.runtime.runner.subscriberCount
                let connections = await api.server.activeConnectionCount
                return runs == 0 && connections == 0
            }
        }
    }

    @Test("the server stopping ends the client's sequence")
    func serverStops() async throws {
        try await withAPI { api in
            let client = api.client()
            let server = api.server
            // Either way the loop must end: normally (the server closed it) or with an error.
            try await withTimeout {
                var iterator = client.events().makeAsyncIterator()
                _ = try await iterator.next()
                await server.stop()
                do {
                    while try await iterator.next() != nil {}
                } catch {}
            }
        }
    }

    @Test("baseURL(port:) is the loopback address and the default is 48600")
    func addresses() {
        #expect(LocalAPIClient.baseURL(port: 48601).absoluteString == "http://127.0.0.1:48601")
        #expect(LocalAPIClient.defaultBaseURL.absoluteString == "http://127.0.0.1:48600")
        #expect(LocalAPIClient(token: nil).baseURL == LocalAPIClient.defaultBaseURL)
    }

    @Test("error descriptions say what happened")
    func descriptions() {
        let url = URL(string: "http://127.0.0.1:48600")!
        #expect(LocalAPIError.unreachable(url, underlying: "refused").description == "cannot reach the Switchboard API at 127.0.0.1:48600: refused")
        #expect(LocalAPIError.unauthorized.description.contains("401"))
        #expect(LocalAPIError.status(409, body: #"{"error":"busy","runId":"abc"}"#).description == "HTTP 409: busy (run abc)")
        #expect(LocalAPIError.status(400, body: #"{"error":"missing parameter","parameter":"port"}"#).description == #"HTTP 400: missing parameter "port""#)
        #expect(LocalAPIError.status(502, body: "bad gateway").description == "HTTP 502: bad gateway")
        #expect(LocalAPIError.status(500, body: "").description == "HTTP 500")
    }
}
