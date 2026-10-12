import Actions
import DDCKit
import Devices
import ESP32Kit
import Foundation
import StateStore
import SwitchboardCore
import Testing

@Suite("ActionRegistry parameter validation")
struct ActionValidationTests {
    private let registry = ActionRegistry()

    private func failure(_ id: ActionID, _ parameters: [String: JSONValue]) -> ActionError? {
        do {
            _ = try registry.validate(id, parameters: parameters)
            return nil
        } catch let error as ActionError {
            return error
        } catch {
            Issue.record("wrong error \(error)")
            return nil
        }
    }

    @Test("good parameters validate", arguments: [
        (ActionID.monitorPBPOn, [String: JSONValue]()),
        (.hdmiSelect, ["display": "dualup", "input": 1]),
        (.hdmiSelect, ["display": "samsung", "input": 2]),
        (.hdmiResync, ["display": "lg4k", "input": 2]),
        (.usbSelect, ["port": 1]), (.usbSelect, ["port": 4]),
        (.delay, ["ms": 0]), (.delay, ["ms": 60000]),
        (.notify, ["text": "hello"]),
        (.usbSelect, ["port": .double(3.0)]),   // a client that writes every number with a fraction
    ])
    func valid(id: ActionID, parameters: [String: JSONValue]) {
        #expect(failure(id, parameters) == nil)
    }

    @Test("a missing parameter is named")
    func missing() {
        #expect(failure(.usbSelect, [:]) == .missingParameter("port"))
        #expect(failure(.hdmiSelect, ["display": "lg4k"]) == .missingParameter("input"))
        #expect(failure(.hdmiSelect, ["input": 1]) == .missingParameter("display"))
        #expect(failure(.delay, [:]) == .missingParameter("ms"))
        #expect(failure(.notify, [:]) == .missingParameter("text"))
    }

    @Test("a null parameter counts as missing")
    func nullIsMissing() {
        #expect(failure(.usbSelect, ["port": nil]) == .missingParameter("port"))
    }

    @Test("out-of-range and mistyped values say what is allowed")
    func invalid() {
        #expect(failure(.usbSelect, ["port": 0]) == .invalidParameter("port", "must be 1 to 4, got 0"))
        #expect(failure(.usbSelect, ["port": 5]) == .invalidParameter("port", "must be 1 to 4, got 5"))
        #expect(failure(.hdmiSelect, ["display": "lg4k", "input": 3]) == .invalidParameter("input", "must be 1 to 2, got 3"))
        #expect(failure(.delay, ["ms": -5]) == .invalidParameter("ms", "must be 0 to 60000, got -5"))
        #expect(failure(.delay, ["ms": 60001]) == .invalidParameter("ms", "must be 0 to 60000, got 60001"))
        #expect(failure(.hdmiResync, ["display": "tv", "input": 1]) == .invalidParameter("display", "must be one of dualup, lg4k, samsung, got \"tv\""))
        #expect(failure(.usbSelect, ["port": "2"]) == .invalidParameter("port", "must be a whole number, got \"2\""))
        #expect(failure(.usbSelect, ["port": 2.5]) == .invalidParameter("port", "must be a whole number, got 2.5"))
        #expect(failure(.usbSelect, ["port": true]) == .invalidParameter("port", "must be a whole number, got true"))
        #expect(failure(.notify, ["text": 5]) == .invalidParameter("text", "must be text, got 5"))
    }

    @Test("a parameter the action does not have is refused")
    func unknownParameter() {
        #expect(failure(.monitorPBPOn, ["port": 2]) == .invalidParameter("port", "monitor.pbp.on has no such parameter"))
        #expect(failure(.usbSelect, ["port": 2, "speed": 1]) == .invalidParameter("speed", "usb.select has no such parameter"))
    }

    @Test("a missing parameter is reported before an unknown one")
    func missingFirst() {
        #expect(failure(.usbSelect, ["por": 2]) == .missingParameter("port"))
    }

    @Test("validated arguments read back typed")
    func arguments() throws {
        let arguments = try registry.validate(.hdmiSelect, parameters: ["display": "lg4k", "input": .double(2.0)])
        #expect(arguments.display() == .lg4k)
        #expect(arguments.int("input") == 2)
    }

    @Test("error text is what a failed run event carries")
    func errorText() {
        #expect(ActionError.unknownID("zzz").description == "unknown action or macro \"zzz\"")
        #expect(ActionError.missingParameter("port").description == "missing parameter \"port\"")
        #expect(ActionError.invalidParameter("port", "must be 1 to 4, got 5").description == "invalid parameter \"port\": must be 1 to 4, got 5")
        #expect(ActionError.busy(runID: "r1").description == "another run is in progress (run r1)")
        #expect(ActionError.verifyFailed(["a", "b"]).description == "verify failed: a; b")
        #expect(ActionError.controller(.timeout).description == "controller did not answer in time")
    }

    @Test("the controller-unavailable message names the setting and the environment variable")
    func controllerHint() {
        let text = ActionError.controllerNotConfigured.description
        #expect(text.contains("controllerURL"))
        #expect(text.contains("SWITCHBOARD_CONTROLLER_URL"))
    }

    @Test("failures are classified for exit codes")
    func classification() {
        let unreachable = ControllerError.unreachable(URL(string: "http://h:1")!, underlying: "refused")
        #expect(ActionError.controller(unreachable).isControllerUnreachable)
        #expect(ActionError.controller(.timeout).isControllerUnreachable)
        #expect(ActionError.controllerNotConfigured.isControllerUnreachable)
        #expect(!ActionError.controller(.httpStatus(400, body: "")).isControllerUnreachable)
        #expect(!ActionError.controller(.invalidResponse("x")).isControllerUnreachable)
        #expect(!ActionError.monitorNotConfigured.isControllerUnreachable)
        #expect(ActionError.busy(runID: "r").isBusy)
        #expect(!ActionError.cancelled.isBusy)

        let outcome = WriteOutcome(command: .pbpOn, transport: "t", expected: 0, observed: 1, verified: false, reading: DualUpReading(raw: [0xD7: 1]))
        #expect(ActionError.unverified(outcome).isUnverifiedWrite)
        #expect(!ActionError.verifyFailed([]).isUnverifiedWrite)
    }

    @Test("an unverified write says what was read and what was expected")
    func unverifiedText() {
        let wrong = WriteOutcome(command: .pbpOn, transport: "t", expected: 0, observed: 1, verified: false, reading: DualUpReading(raw: [0xD7: 1]))
        #expect(ActionError.unverified(wrong).description == "unverified: 0xD7 read back 1 (off), expected 0 (on)")
        let unreadable = WriteOutcome(command: .pbpOff, transport: "t", expected: 1, observed: nil, verified: false, reading: DualUpReading(raw: [:]))
        #expect(ActionError.unverified(unreadable).description == "unverified: 0xD7 unreadable, expected 1 (off)")
        let odd = WriteOutcome(command: .pbpOff, transport: "t", expected: 1, observed: 7, verified: false, reading: DualUpReading(raw: [0xD7: 7]))
        #expect(ActionError.unverified(odd).description == "unverified: 0xD7 read back 7 (unexpected value), expected 1 (off)")
    }
}

@MainActor
@Suite("ActionRegistry.run")
struct ActionRunTests {
    private let registry = ActionRegistry()

    @Test("monitor.pbp.on writes over the USB bridge, verifies on the video cable and updates the store")
    func pbpOn() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            let message = try await registry.run(.monitorPBPOn, parameters: [:], context: rig.context)

            #expect(message == "monitor.pbp.on: verified 0xD7 = 0")
            #expect(await rig.monitor.writes == ["USB bridge: 0xD7 = 0"])
            #expect(rig.store.state.pbp == .on)
            #expect(rig.store.state.mainInput == .hdmi1)
            #expect(rig.store.state.dualUpReachable)
            #expect(rig.store.state.updatedAt > .distantPast)
        }
    }

    @Test("monitor.pbp.off writes over the video cable and verifies")
    func pbpOff() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory, monitor: FakeMonitor(pbp: 0))
            let message = try await registry.run(.monitorPBPOff, parameters: [:], context: rig.context)

            #expect(message == "monitor.pbp.off: verified 0xD7 = 1")
            #expect(await rig.monitor.writes == ["video cable: 0xD7 = 1"])
            #expect(rig.store.state.pbp == .off)
        }
    }

    @Test("an unverified write throws unverified, but what was read still reaches the store")
    func unverified() async throws {
        try await withTempDirectory { directory in
            let (dualUp, cable, bridge) = stuckOffDualUp()
            let rig = Rig(directory: directory, dualUp: dualUp)

            do {
                _ = try await registry.run(.monitorPBPOn, parameters: [:], context: rig.context)
                Issue.record("expected unverified")
            } catch let error as ActionError {
                guard case .unverified(let outcome) = error else { Issue.record("wrong error \(error)"); return }
                #expect(!outcome.verified)
                #expect(outcome.observed == 1)
                #expect(error.description == "unverified: 0xD7 read back 1 (off), expected 0 (on)")
            }
            #expect(rig.store.state.pbp == .off)
            #expect(rig.store.state.dualUpReachable)
            #expect(await bridge.writes.count == 1)
            #expect(await cable.writes.isEmpty)
        }
    }

    @Test("an unreadable monitor after the write is unverified too")
    func unreadable() async throws {
        try await withTempDirectory { directory in
            let cable = FakeDDC(name: "cable")   // never answers
            let dualUp = LGDualUp(videoCable: cable, usbBridge: FakeDDC(name: "bridge", supportsRead: false), sleep: instant)
            let rig = Rig(directory: directory, dualUp: dualUp)

            await #expect(throws: ActionError.self) { try await registry.run(.monitorPBPOn, parameters: [:], context: rig.context) }
            #expect(rig.store.state.pbp == .unknown)
            #expect(!rig.store.state.dualUpReachable)
        }
    }

    @Test("a write error becomes monitorUnavailable with the underlying message")
    func writeError() async throws {
        try await withTempDirectory { directory in
            // No USB bridge: LGDualUp's video-cable-only initialiser puts an UnavailableTransport there.
            let dualUp = LGDualUp(videoCable: FakeDDC(reads: [0xD7: [1]]), sleep: instant)
            let rig = Rig(directory: directory, dualUp: dualUp)

            do {
                _ = try await registry.run(.monitorPBPOn, parameters: [:], context: rig.context)
                Issue.record("expected an error")
            } catch let error as ActionError {
                guard case .monitorUnavailable(let message) = error else { Issue.record("wrong error \(error)"); return }
                #expect(message.contains("LG USB bridge not found"))
            }
            #expect(rig.store.state.updatedAt == .distantPast, "a write that never happened leaves the state alone")
        }
    }

    @Test("monitor.read reads the state into the store without writing")
    func read() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory, monitor: FakeMonitor(pbp: 0, mainInput: 2))
            let message = try await registry.run(.monitorRead, parameters: [:], context: rig.context)

            #expect(message == "monitor.read: pbp on, main input hdmi2")
            #expect(rig.store.state.pbp == .on)
            #expect(rig.store.state.mainInput == .hdmi2)
            #expect(rig.store.state.dualUpReachable)
            #expect(await rig.monitor.writes.isEmpty)
        }
    }

    @Test("monitor.read with nothing readable fails and marks the monitor unreachable")
    func readNothing() async throws {
        try await withTempDirectory { directory in
            let dualUp = LGDualUp(videoCable: FakeDDC(), sleep: instant)
            let rig = Rig(directory: directory, dualUp: dualUp)
            rig.store.setDualUpReachable(true)

            do {
                _ = try await registry.run(.monitorRead, parameters: [:], context: rig.context)
                Issue.record("expected an error")
            } catch let error as ActionError {
                guard case .monitorUnavailable = error else { Issue.record("wrong error \(error)"); return }
            }
            #expect(!rig.store.state.dualUpReachable)
            #expect(rig.store.state.pbp == .unknown)
        }
    }

    @Test("hdmi.select, hdmi.resync and usb.select go to the controller and put its answer in the store")
    func controllerActions() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)

            let select = try await registry.run(.hdmiSelect, parameters: ["display": "lg4k", "input": 2], context: rig.context)
            #expect(select == "hdmi.select: lg4k input 2")
            #expect(rig.store.state.hdmiInput[.lg4k] == 2)

            let resync = try await registry.run(.hdmiResync, parameters: ["display": "samsung", "input": 2], context: rig.context)
            #expect(resync == "hdmi.resync: samsung assumed input 2")
            #expect(rig.store.state.hdmiInput[.samsung] == 2)

            let usb = try await registry.run(.usbSelect, parameters: ["port": 3], context: rig.context)
            #expect(usb == "usb.select: port 3")
            #expect(rig.store.state.usbPort == 3)
            #expect(rig.store.state.controllerReachable)

            #expect(await rig.controller.calls == ["selectHDMI(lg4k, 2)", "resyncHDMI(samsung, 2)", "selectUSB(3)"])
            #expect(await rig.monitor.writes.isEmpty, "controller actions never touch the monitor")
        }
    }

    @Test("a controller that cannot be reached throws controller(...) and marks it unreachable")
    func controllerUnreachable() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            rig.store.setControllerReachable(true)
            let error = ControllerError.unreachable(URL(string: "http://192.168.1.50:80")!, underlying: "connection refused")
            await rig.controller.fail(with: error)

            await #expect(throws: ActionError.controller(error)) {
                try await registry.run(.usbSelect, parameters: ["port": 2], context: rig.context)
            }
            #expect(!rig.store.state.controllerReachable)
            #expect(rig.store.state.usbPort == nil)
        }
    }

    @Test("a controller that answers with an HTTP error keeps its reachability")
    func controllerRefuses() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            rig.store.setControllerReachable(true)
            await rig.controller.fail(with: .httpStatus(400, body: #"{"error":"bad port"}"#))

            await #expect(throws: ActionError.controller(.httpStatus(400, body: #"{"error":"bad port"}"#))) {
                try await registry.run(.usbSelect, parameters: ["port": 2], context: rig.context)
            }
            #expect(rig.store.state.controllerReachable)
        }
    }

    @Test("a controller that answers without doing what was asked fails, and its state is recorded")
    func controllerDidNotComply() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            await rig.controller.ignoreRequests(true)

            await #expect(throws: ActionError.verifyFailed(["usbPort: expected 2, got 1"])) {
                try await registry.run(.usbSelect, parameters: ["port": 2], context: rig.context)
            }
            await #expect(throws: ActionError.verifyFailed(["hdmiInput.lg4k: expected 2, got 1"])) {
                try await registry.run(.hdmiSelect, parameters: ["display": "lg4k", "input": 2], context: rig.context)
            }
            #expect(rig.store.state.usbPort == 1, "the store shows what the controller said, not what was asked")
        }
    }

    @Test("with no controller the hdmi and usb actions say which setting to fix")
    func noController() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory, withController: false)
            let cases: [(ActionID, [String: JSONValue])] = [
                (.hdmiSelect, ["display": "lg4k", "input": 1]), (.hdmiResync, ["display": "lg4k", "input": 1]), (.usbSelect, ["port": 1]),
            ]
            for (id, parameters) in cases {
                do {
                    _ = try await registry.run(id, parameters: parameters, context: rig.context)
                    Issue.record("\(id) should need a controller")
                } catch let error as ActionError {
                    guard case .controllerUnavailable(let message) = error else { Issue.record("wrong error \(error)"); return }
                    #expect(message.contains("controllerURL") && message.contains("SWITCHBOARD_CONTROLLER_URL"))
                }
            }
        }
    }

    @Test("with no monitor the monitor actions fail without touching anything")
    func noMonitor() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory, withMonitor: false)
            for id in [ActionID.monitorPBPOn, .monitorPBPOff, .monitorRead] {
                await #expect(throws: ActionError.monitorNotConfigured) { try await registry.run(id, parameters: [:], context: rig.context) }
            }
            #expect(rig.store.state.updatedAt == .distantPast)
        }
    }

    @Test("delay waits through the injected sleeper, not the clock")
    func delay() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            let message = try await registry.run(.delay, parameters: ["ms": 500], context: rig.context)
            #expect(message == "delay: 500 ms")
            #expect(rig.sleeper.durations == [.milliseconds(500)])
            _ = try await registry.run(.delay, parameters: ["ms": 0], context: rig.context)
            #expect(rig.sleeper.durations == [.milliseconds(500), .milliseconds(0)])
        }
    }

    @Test("notify hands the text to the context's closure")
    func notify() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            let message = try await registry.run(.notify, parameters: ["text": "Guest mode"], context: rig.context)
            #expect(message == "notify: Guest mode")
            #expect(rig.notified.all == ["Guest mode"])
        }
    }

    @Test("run validates before it acts")
    func validatesFirst() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            await #expect(throws: ActionError.missingParameter("port")) { try await registry.run(.usbSelect, parameters: [:], context: rig.context) }
            await #expect(throws: ActionError.invalidParameter("port", "must be 1 to 4, got 9")) {
                try await registry.run(.usbSelect, parameters: ["port": 9], context: rig.context)
            }
            #expect(await rig.controller.calls.isEmpty)
        }
    }
}
