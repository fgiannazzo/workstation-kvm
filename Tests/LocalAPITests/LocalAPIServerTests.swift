import Actions
import Foundation
import LocalAPI
import StateStore
import SwitchboardCore
import Testing
import TinyHTTP

@MainActor
@Suite("LocalAPIServer: requests")
struct LocalAPIServerTests {
    // MARK: Health and authentication

    @Test("GET /health needs no token and reports the name and the version")
    func health() async throws {
        try await withAPI(version: "9.9.9") { api in
            let reply = try await api.anonymous("GET", "/health")
            #expect(reply.status == 200)
            #expect(reply.headers["content-type"]?.hasPrefix("application/json") == true)
            #expect(reply.text == #"{"name":"Switchboard","ok":true,"version":"9.9.9"}"#)

            // A wrong token on /health is not an error: the route does not look at it.
            let wrong = try await api.request("GET", "/health", auth: .bearer("nope"))
            #expect(wrong.status == 200)
            // HEAD on it works too, as for any GET route.
            let head = try await api.anonymous("HEAD", "/health")
            #expect(head.status == 200)
        }
    }

    @Test("the default version is SwitchboardVersion.current, 0.1.0")
    func defaultVersion() async throws {
        #expect(SwitchboardVersion.current == "0.1.0")
        try await withAPI { api in
            let reply = try await api.anonymous("GET", "/health")
            #expect(try reply.json()["version"] as? String == "0.1.0")
        }
    }

    @Test("every other route answers 401 {\"error\":\"unauthorized\"} without a token and with a wrong one")
    func unauthorized() async throws {
        try await withAPI { api in
            let routes: [(String, String)] = [
                ("GET", "/state"), ("GET", "/actions"), ("GET", "/macros"), ("GET", "/events"),
                ("POST", "/run/solo"), ("POST", "/run/usb.select"), ("GET", "/nothing-here"), ("DELETE", "/state"),
            ]
            for (method, path) in routes {
                let anonymous = try await api.anonymous(method, path, body: method == "POST" ? #"{"port":2}"# : nil)
                #expect(anonymous.status == 401, "\(method) \(path) without a token")
                #expect(anonymous.text == #"{"error":"unauthorized"}"#, "\(method) \(path)")

                let wrong = try await api.request(method, path, auth: .bearer("not-the-token"), body: method == "POST" ? #"{"port":2}"# : nil)
                #expect(wrong.status == 401, "\(method) \(path) with a wrong token")
            }
            // Nothing ran behind the 401s.
            #expect(await api.runtime.runner.currentRun == nil)
            #expect(await api.runtime.runner.activity.started == 0)
            #expect(await api.controller.calls.isEmpty)
        }
    }

    @Test("a token that is a prefix of the real one, or the real one with more, is wrong; so is another scheme")
    func nearMisses() async throws {
        try await withAPI(token: "abcdefghijklmnop") { api in
            for wrong in ["abcdefghijklmno", "abcdefghijklmnopq", "ABCDEFGHIJKLMNOP", "abcdefghijklmnoP", ""] {
                let reply = try await api.request("GET", "/state", auth: .bearer(wrong))
                #expect(reply.status == 401, "token \"\(wrong)\"")
            }
            let basic = try await api.request("GET", "/state", auth: .none, headers: ["Authorization": "Basic abcdefghijklmnop"])
            #expect(basic.status == 401)
            let bare = try await api.request("GET", "/state", auth: .none, headers: ["Authorization": "abcdefghijklmnop"])
            #expect(bare.status == 401)
            let right = try await api.request("GET", "/state")
            #expect(right.status == 200)
            // The scheme name is case-insensitive.
            let lowercase = try await api.request("GET", "/state", auth: .none, headers: ["Authorization": "bearer abcdefghijklmnop"])
            #expect(lowercase.status == 200)
        }
    }

    @Test("a token in the query string is never accepted, on any route")
    func queryTokenIsRefused() async throws {
        try await withAPI { api in
            for path in ["/state", "/actions", "/macros", "/events"] {
                let reply = try await api.anonymous("GET", "\(path)?token=\(api.token)")
                #expect(reply.status == 401, "GET \(path)?token=…")
            }
            let run = try await api.anonymous("POST", "/run/solo?token=\(api.token)")
            #expect(run.status == 401)
            #expect(await api.runtime.runner.currentRun == nil)
            // And the same token in the header works.
            let header = try await api.request("GET", "/state?token=ignored")
            #expect(header.status == 200)
        }
    }

    @Test("an empty server token authenticates nobody")
    func emptyToken() async throws {
        try await withAPI(token: "") { api in
            for auth in [Harness.Auth.none, .bearer(""), .bearer("x")] {
                let reply = try await api.request("GET", "/state", auth: auth)
                #expect(reply.status == 401)
            }
        }
    }

    @Test("with the token, an unknown path is 404 and a wrong method is 405")
    func routing() async throws {
        try await withAPI { api in
            let missing = try await api.request("GET", "/nothing-here")
            #expect(missing.status == 404)
            #expect(missing.text == #"{"error":"not found"}"#)
            let wrongMethod = try await api.request("POST", "/state")
            #expect(wrongMethod.status == 405)
            #expect(wrongMethod.headers["allow"] == "GET")
        }
    }

    // MARK: State

    @Test("GET /state is the SwitchboardState of the store, dates as ISO 8601 with milliseconds and Z")
    func state() async throws {
        try await withAPI { api in
            api.store.applyMonitor(pbp: .on, mainInput: .hdmi2, reachable: true)
            api.store.apply(ControllerState(hdmi: [.dualup: 1, .lg4k: 2, .samsung: 1], usb: .init(port: 2, source: "aten"), uptime: 7))
            api.store.setLastError("boom")

            let reply = try await api.request("GET", "/state")
            #expect(reply.status == 200)
            #expect(reply.headers["content-type"]?.hasPrefix("application/json") == true)

            let decoded = try APIJSON.makeDecoder().decode(SwitchboardState.self, from: reply.body)
            #expect(decoded == api.store.state)
            #expect(decoded.pbp == .on)
            #expect(decoded.mainInput == .hdmi2)
            #expect(decoded.usbPort == 2)
            #expect(decoded.hdmiInput == [.dualup: 1, .lg4k: 2, .samsung: 1])
            #expect(decoded.controllerReachable)
            #expect(decoded.dualUpReachable)
            #expect(decoded.lastError == "boom")

            let json = try reply.json()
            let updatedAt = try #require(json["updatedAt"] as? String)
            let shape = try Regex(#"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#)
            #expect(updatedAt.wholeMatch(of: shape) != nil, "updatedAt is \(updatedAt)")
            #expect(updatedAt == "2026-10-11T20:15:03.120Z")
            #expect(json["pbp"] as? String == "on")
            #expect(json["hdmiInput"] as? [String: Int] == ["dualup": 1, "lg4k": 2, "samsung": 1])
        }
    }

    @Test("a fresh state keeps its nulls: usbPort and lastError are null, not absent")
    func freshState() async throws {
        try await withAPI { api in
            let reply = try await api.request("GET", "/state")
            let json = try reply.json()
            #expect(json["pbp"] as? String == "unknown")
            #expect(json["mainInput"] as? String == "unknown")
            #expect(json.keys.contains("usbPort") && json["usbPort"] is NSNull)
            #expect(json.keys.contains("lastError") && json["lastError"] is NSNull)
            #expect((json["hdmiInput"] as? [String: Any])?.isEmpty == true)
            #expect(json["controllerReachable"] as? Bool == false)
            #expect(json["updatedAt"] as? String == "0001-01-01T00:00:00.000Z", "never updated")
            #expect(reply.text.contains("\n") == false, "one line, no pretty printing")
        }
    }

    // MARK: Actions and macros

    @Test("GET /actions is the registry's ActionList, byte for byte, in API.md order")
    func actions() async throws {
        try await withAPI { api in
            let reply = try await api.request("GET", "/actions")
            #expect(reply.status == 200)
            let expected = try APIJSON.makeEncoder().encode(ActionList(actions: api.runtime.registry.descriptors))
            #expect(reply.body == expected)

            let list = try APIJSON.makeDecoder().decode(ActionList.self, from: reply.body)
            #expect(list.actions.map(\.id.rawValue) == [
                "monitor.pbp.on", "monitor.pbp.off", "monitor.read", "hdmi.select", "hdmi.resync", "usb.select", "delay", "notify",
                "displays.off", "displays.on",
            ])
            let usb = try #require(list.actions.first { $0.id == .usbSelect })
            #expect(usb.parameters == [.int("port", min: 1, max: 4)])
        }
    }

    @Test("GET /macros is the macro store: the defaults guest and solo on first use")
    func macros() async throws {
        try await withAPI { api in
            let reply = try await api.request("GET", "/macros")
            #expect(reply.status == 200)
            let stored = try await api.runtime.macros.macros()
            #expect(reply.body == (try APIJSON.makeEncoder().encode(MacroFile(macros: stored))))

            let file = try APIJSON.makeDecoder().decode(MacroFile.self, from: reply.body)
            #expect(file.macros.map(\.id) == ["guest", "solo"])
            #expect(file.macros == MacroStore.defaultMacros)

            // Steps are an action plus its parameters as sibling keys, as API.md shows.
            let json = try reply.json()
            let first = try #require((json["macros"] as? [[String: Any]])?.first)
            let steps = try #require(first["steps"] as? [[String: Any]])
            #expect(steps[1]["action"] as? String == "usb.select")
            #expect(steps[1]["port"] as? Int == 2)
            #expect((first["verify"] as? [String: Any])?["pbp"] as? String == "on")
        }
    }

    @Test("a macro that was saved shows up in GET /macros")
    func savedMacro() async throws {
        try await withAPI { api in
            try await api.runtime.macros.upsert(Macro(id: "pause", name: "Pause", steps: [MacroStep(action: .delay, parameters: ["ms": 10])]))
            let file = try APIJSON.makeDecoder().decode(MacroFile.self, from: try await api.request("GET", "/macros").body)
            #expect(file.macros.map(\.id) == ["guest", "solo", "pause"])
        }
    }

    @Test("a macros.json that cannot be read is a 500 with the reason, not a crash")
    func brokenMacroFile() async throws {
        try await withAPI { api in
            try FileManager.default.createDirectory(at: api.runtime.macros.directory, withIntermediateDirectories: true)
            try Data("{ not json".utf8).write(to: api.runtime.macros.fileURL)
            let reply = try await api.request("GET", "/macros")
            #expect(reply.status == 500)
            #expect((try reply.json()["error"] as? String)?.contains("macros.json") == true)
        }
    }

    // MARK: POST /run/{id}

    @Test("POST /run/usb.select {\"port\":2}: 202 with the handle, then started, step and finished on /events")
    func runAction() async throws {
        try await withAPI { api in
            let events = try await EventCollector.open(api)
            #expect(events.status == 200)
            #expect(events.events.first?.event == "state", "a state event comes first, on connect")

            let reply = try await api.request("POST", "/run/usb.select", body: #"{"port":2}"#)
            #expect(reply.status == 202)
            let handle = try APIJSON.makeDecoder().decode(RunHandle.self, from: reply.body)
            #expect(handle.id == "usb.select")
            #expect(handle.kind == .action)
            #expect(!handle.runId.isEmpty)
            let json = try reply.json()
            #expect(Set(json.keys) == ["runId", "id", "kind"])
            #expect(json["kind"] as? String == "action")

            // The state event that shows the new port can arrive after `finished`: they travel
            // on two streams.
            let seen = await events.wait { collected in
                let runs = collected.filter { $0.event == "run" }.compactMap { try? $0.decoded(RunEvent.self) }
                let states = collected.filter { $0.event == "state" }.compactMap { try? $0.decoded(SwitchboardState.self) }
                return runs.last?.status == .finished && states.contains { $0.usbPort == 2 }
            }
            #expect(seen)

            let all = events.events
            #expect(all.first?.event == "state")
            let runs = try all.filter { $0.event == "run" }.map { try $0.decoded(RunEvent.self) }
            #expect(runs.map(\.status) == [.started, .step, .finished])
            #expect(runs.map(\.step) == [0, 1, 1])
            #expect(runs.allSatisfy { $0.runId == handle.runId && $0.id == "usb.select" && $0.kind == .action && $0.stepCount == 1 })
            #expect(runs.map(\.message) == ["", "usb.select: port 2", "ok"])
            #expect(await api.controller.calls == ["selectUSB(2)"])
            #expect(api.store.state.usbPort == 2)

            // One JSON document per data: line, and the run event has all seven keys.
            let dataLines = events.rawLines.filter { $0.hasPrefix("data:") }
            #expect(dataLines.count == all.count)
            for line in dataLines {
                let text = String(line.dropFirst("data:".count))
                #expect((try? JSONSerialization.jsonObject(with: Data(text.utf8))) is [String: Any], "not one JSON object: \(line)")
            }
            let runLine = try #require(all.first { $0.event == "run" })
            let runObject = try #require(try JSONSerialization.jsonObject(with: Data(runLine.data.utf8)) as? [String: Any])
            #expect(Set(runObject.keys) == ["runId", "id", "kind", "status", "step", "stepCount", "message"])
            events.close()
        }
    }

    @Test("a macro run: kind macro, two steps, and the same event order")
    func runMacro() async throws {
        try await withAPI { api in
            let events = try await EventCollector.open(api)
            let reply = try await api.request("POST", "/run/solo")
            #expect(reply.status == 202)
            let handle = try APIJSON.makeDecoder().decode(RunHandle.self, from: reply.body)
            #expect(handle.id == "solo")
            #expect(handle.kind == .macro)

            _ = await events.wait { collected in
                collected.contains { $0.event == "run" && ((try? $0.decoded(RunEvent.self))?.isTerminal ?? false) }
            }
            let runs = try events.events.filter { $0.event == "run" }.map { try $0.decoded(RunEvent.self) }
            #expect(runs.map(\.status) == [.started, .step, .step, .finished])
            #expect(runs.map(\.step) == [0, 1, 2, 2])
            #expect(runs.allSatisfy { $0.stepCount == 2 && $0.kind == .macro })
            #expect(runs.last?.message == "ok")
            events.close()
        }
    }

    @Test("a run that fails is a failed event with the error, and the exit code family can be read from it")
    func runFails() async throws {
        try await withAPI { api in
            // guest turns PBP on over the bridge; the fake cable keeps reading 1 (off), so the write is unverified.
            let events = try await EventCollector.open(api)
            let reply = try await api.request("POST", "/run/guest")
            #expect(reply.status == 202)

            _ = await events.wait { collected in
                collected.contains { $0.event == "run" && ((try? $0.decoded(RunEvent.self))?.isTerminal ?? false) }
            }
            let runs = try events.events.filter { $0.event == "run" }.map { try $0.decoded(RunEvent.self) }
            #expect(runs.map(\.status) == [.started, .failed])
            let failure = try #require(runs.last)
            #expect(failure.step == 1)
            #expect(failure.message.hasPrefix("monitor.pbp.on: unverified:"))
            #expect(failure.failureKind == .unverifiedWrite)
            #expect(api.store.state.lastError?.hasPrefix("guest: ") == true)
            events.close()
        }
    }

    @Test("POST /run/{unknown}: 404 unknown id")
    func unknownID() async throws {
        try await withAPI { api in
            let reply = try await api.request("POST", "/run/nope")
            #expect(reply.status == 404)
            #expect(reply.text == #"{"error":"unknown id","id":"nope"}"#)
            #expect(await api.runtime.runner.activity.started == 0)
        }
    }

    @Test("a missing parameter is 400 with its name; an invalid one is 400 invalid parameter")
    func parameterErrors() async throws {
        try await withAPI { api in
            let missing = try await api.request("POST", "/run/usb.select")
            #expect(missing.status == 400)
            #expect(missing.text == #"{"error":"missing parameter","parameter":"port"}"#)

            let emptyObject = try await api.request("POST", "/run/hdmi.select", body: "{}")
            #expect(emptyObject.status == 400)
            #expect(emptyObject.text == #"{"error":"missing parameter","parameter":"display"}"#)

            let invalid = try await api.request("POST", "/run/usb.select", body: #"{"port":9}"#)
            #expect(invalid.status == 400)
            let json = try invalid.json()
            #expect(json["error"] as? String == "invalid parameter")
            #expect(json["parameter"] as? String == "port")
            #expect((json["reason"] as? String)?.isEmpty == false)

            let wrongType = try await api.request("POST", "/run/usb.select", body: #"{"port":"two"}"#)
            #expect(wrongType.status == 400)
            #expect(try wrongType.json()["error"] as? String == "invalid parameter")

            // Nothing was started by any of them.
            #expect(await api.runtime.runner.activity.started == 0)
            #expect(await api.controller.calls.isEmpty)
        }
    }

    @Test("a body that is not a JSON object is 400 invalid body; null and whitespace mean no parameters")
    func bodyShapes() async throws {
        try await withAPI { api in
            for body in ["{ nope", "[1,2]", "\"port\"", "2"] {
                let reply = try await api.request("POST", "/run/usb.select", body: body)
                #expect(reply.status == 400, "body \(body)")
                #expect(try reply.json()["error"] as? String == "invalid body")
            }
            // Macros ignore the body entirely, as API.md says.
            let macro = try await api.request("POST", "/run/solo", body: #"{"port":4}"#)
            #expect(macro.status == 202)
            await eventually { await api.runtime.runner.currentRun == nil }

            let nothing = try await api.request("POST", "/run/monitor.read", body: "null")
            #expect(nothing.status == 202)
        }
    }

    @Test("a second run while one is in progress is 409 busy with the running run's id; afterwards runs work again")
    func busy() async throws {
        try await withAPI(holdDelays: true) { api in
            let first = try await api.request("POST", "/run/delay", body: #"{"ms":5000}"#)
            #expect(first.status == 202)
            let handle = try APIJSON.makeDecoder().decode(RunHandle.self, from: first.body)

            let second = try await api.request("POST", "/run/usb.select", body: #"{"port":2}"#)
            #expect(second.status == 409)
            #expect(second.text == #"{"error":"busy","runId":"\#(handle.runId)"}"#)
            // A macro is refused the same way.
            let third = try await api.request("POST", "/run/solo")
            #expect(third.status == 409)
            #expect(await api.controller.calls.isEmpty, "the refused runs did nothing")

            await api.delayGate.release()
            let finished = await api.runtime.runner.wait(handle)
            #expect(finished.status == .finished)

            let after = try await api.request("POST", "/run/usb.select", body: #"{"port":2}"#)
            #expect(after.status == 202)
        }
    }

    @Test("an id with a dot, a dash or an underscore reaches the router intact")
    func idCharacters() async throws {
        try await withAPI { api in
            try await api.runtime.macros.upsert(Macro(id: "my_macro-2.0", name: "Odd", steps: [MacroStep(action: .monitorRead)]))
            let reply = try await api.request("POST", "/run/my_macro-2.0")
            #expect(reply.status == 202)
            #expect(try reply.json()["id"] as? String == "my_macro-2.0")
        }
    }

    // MARK: GET /events

    @Test("the stream opens with exactly one state event, as text/event-stream, and sends no run event until a run")
    func eventsOnConnect() async throws {
        try await withAPI { api in
            api.store.applyMonitor(pbp: .off, mainInput: .hdmi1, reachable: true)
            let events = try await EventCollector.open(api)
            try await Task.sleep(for: .milliseconds(100))

            #expect(events.status == 200)
            #expect(events.events.count == 1)
            let first = try #require(events.events.first)
            #expect(first.event == "state")
            #expect(try first.decoded(SwitchboardState.self) == api.store.state)
            events.close()
        }
    }

    @Test("every store mutation is a state event")
    func stateChanges() async throws {
        try await withAPI { api in
            let events = try await EventCollector.open(api)
            api.store.applyMonitor(pbp: .on, mainInput: .hdmi1, reachable: true)
            api.store.setLastError("trouble")

            let seen = await events.wait { collected in
                let states = collected.compactMap { try? $0.decoded(SwitchboardState.self) }
                return states.contains { $0.pbp == .on } && states.last?.lastError == "trouble"
            }
            #expect(seen)
            #expect(events.events.allSatisfy { $0.event == "state" })
            events.close()
        }
    }

    @Test("an idle stream gets a `: keepalive` comment every interval; it is a comment, not an event")
    func keepalive() async throws {
        try await withAPI(keepalive: .milliseconds(40)) { api in
            let events = try await EventCollector.open(api)
            await eventually { events.rawLines.filter { $0 == ": keepalive" }.count >= 2 }
            #expect(events.events.count == 1, "comments are not events")
            events.close()
        }
    }

    @Test("a client that disconnects releases its subscriptions and its connection")
    func disconnect() async throws {
        try await withAPI { api in
            let events = try await EventCollector.open(api)
            #expect(await api.runtime.runner.subscriberCount == 1)
            #expect(api.store.subscriberCount == 1)
            #expect(await api.server.activeConnectionCount == 1)

            events.close()

            await eventually(.seconds(5), "the subscriptions were not released") {
                let runs = await api.runtime.runner.subscriberCount
                let states = await MainActor.run { api.store.subscriberCount }
                let connections = await api.server.activeConnectionCount
                return runs == 0 && states == 0 && connections == 0
            }
        }
    }

    @Test("several clients each get every event; one leaving does not disturb the others")
    func twoClients() async throws {
        try await withAPI { api in
            let first = try await EventCollector.open(api)
            let second = try await EventCollector.open(api)
            #expect(await api.runtime.runner.subscriberCount == 2)

            first.close()
            api.store.setLastError("still there")
            let seen = await second.wait { collected in
                collected.compactMap { try? $0.decoded(SwitchboardState.self) }.last?.lastError == "still there"
            }
            #expect(seen)
            second.close()
        }
    }

    @Test("stopping the server ends the open streams")
    func stopEndsStreams() async throws {
        try await withAPI { api in
            let events = try await EventCollector.open(api)
            await api.server.stop()
            await eventually { events.finished }
            #expect(await api.server.isRunning == false)
        }
    }

    // MARK: The server itself

    @Test("start binds the port it reports, stop gives it back, and the host is loopback by default")
    func lifecycle() async throws {
        try await withAPI { api in
            let port = await api.server.port
            #expect(port != 0)
            #expect(api.server.host == "127.0.0.1")
            #expect(await api.server.url == URL(string: "http://127.0.0.1:\(port)"))
            #expect(await api.server.isRunning)

            await api.server.stop()
            #expect(await api.server.isRunning == false)
            #expect(await api.server.port == 0, "back to the requested port, 0 here")
            await #expect(throws: (any Error).self) { _ = try await api.request("GET", "/health") }
        }
    }

    @Test("a second server on a taken port fails to start instead of sharing it")
    func portInUse() async throws {
        try await withAPI { api in
            let port = await api.server.port
            let other = LocalAPIServer(runtime: api.runtime, port: port, token: "other")
            await #expect(throws: (any Error).self) { try await other.start() }
            // And the first one still answers.
            let reply = try await api.anonymous("GET", "/health")
            #expect(reply.status == 200)
        }
    }

    @Test("start(runtime:) takes the port from the settings and the token from the store, making it once")
    func startFactory() async throws {
        try await withTempDirectory { directory in
            let runtime = makeFakeRuntime(settings: Settings(localAPIPort: 0), directory: directory)
            let tokens = FileTokenStore(url: directory.appending(path: "token"))
            let before = try tokens.load()
            #expect(before == nil)

            let server = try await LocalAPIServer.start(runtime: runtime, tokenStore: tokens, version: "3.2.1")
            let token = try #require(try tokens.load())
            #expect(token.count == 43)
            let port = await server.port
            #expect(port != 0)

            let client = LocalAPIClient(baseURL: LocalAPIClient.baseURL(port: Int(port)), token: token)
            let health = try await client.health()
            #expect(health.version == "3.2.1")
            let state = try await client.state()
            #expect(state == runtime.store.state)
            await #expect(throws: LocalAPIError.unauthorized) { _ = try await LocalAPIClient(baseURL: client.baseURL, token: "wrong").state() }
            await server.stop()

            // A second start finds the same token instead of making another.
            let again = try await LocalAPIServer.start(runtime: runtime, tokenStore: tokens)
            let reloaded = try tokens.load()
            #expect(reloaded == token)
            await again.stop()
        }
    }

    @Test("start(runtime:) refuses a setting that is not a port number")
    func startFactoryInvalidPort() async throws {
        try await withTempDirectory { directory in
            for port in [70_000, -1, 65_536] {
                let runtime = makeFakeRuntime(settings: Settings(localAPIPort: port), directory: directory)
                let tokens = FileTokenStore(url: directory.appending(path: "token"))
                await #expect(throws: LocalAPIServerError.invalidPort(port)) {
                    _ = try await LocalAPIServer.start(runtime: runtime, tokenStore: tokens)
                }
                let stored = try tokens.load()
                #expect(stored == nil, "no token is made for a server that cannot start")
            }
        }
    }
}
