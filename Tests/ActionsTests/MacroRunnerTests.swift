import Actions
import DDCKit
import Devices
import ESP32Kit
import Foundation
import StateStore
import SwitchboardCore
import Testing

@MainActor
@Suite("MacroRunner")
struct MacroRunnerTests {
    // MARK: Running a macro

    @Test("guest: started, step, step, finished; the state shows PBP on and USB port 2; verify passes")
    func guest() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            let (handle, events) = try await runAndCollect(rig.runner, "guest")

            #expect(handle.id == "guest")
            #expect(handle.kind == .macro)
            #expect(summary(events) == ["started:0/2", "step:1/2", "step:2/2", "finished:2/2"])
            #expect(events.map(\.message) == ["", "monitor.pbp.on: verified 0xD7 = 0", "usb.select: port 2", "ok"])
            #expect(Set(events.map(\.runId)) == [handle.runId])
            #expect(events.allSatisfy { $0.id == "guest" && $0.kind == .macro })

            #expect(rig.store.state.pbp == .on)
            #expect(rig.store.state.usbPort == 2)
            #expect(rig.store.state.lastError == nil)
            #expect(await rig.monitor.writes == ["USB bridge: 0xD7 = 0"])
            #expect(await rig.controller.calls == ["selectUSB(2)"])
        }
    }

    @Test("solo after guest: USB back to port 1, PBP off over the video cable")
    func solo() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            _ = try await runAndCollect(rig.runner, "guest")
            let (_, events) = try await runAndCollect(rig.runner, "solo")

            #expect(summary(events) == ["started:0/2", "step:1/2", "step:2/2", "finished:2/2"])
            #expect(events.map(\.message) == ["", "usb.select: port 1", "monitor.pbp.off: verified 0xD7 = 1", "ok"])
            #expect(rig.store.state.pbp == .off)
            #expect(rig.store.state.usbPort == 1)
            #expect(await rig.monitor.writes == ["USB bridge: 0xD7 = 0", "video cable: 0xD7 = 1"])
        }
    }

    @Test("wait returns the terminal event, before or after the run ends")
    func waitForTerminal() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            let handle = try await rig.runner.start(id: "guest")
            let terminal = await rig.runner.wait(handle)
            #expect(terminal.status == .finished)
            #expect(terminal.step == 2)
            #expect(terminal.message == "ok")
            // Asking again, after the fact, gives the same answer.
            #expect(await rig.runner.wait(handle) == terminal)
            #expect(await rig.runner.error(of: handle) == nil)
        }
    }

    @Test("a run no one started has no terminal event")
    func waitForStranger() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            let stranger = RunHandle(runId: "nope", id: "guest", kind: .macro)
            let event = await rig.runner.wait(stranger)
            #expect(event.status == .failed)
            #expect(event.message == "no such run")
        }
    }

    @Test("every step is logged to the store")
    func logging() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            _ = try await runAndCollect(rig.runner, "guest")
            let lines = rig.store.log.map(\.message)
            #expect(lines == [
                "run guest started (2 steps)",
                "run guest step 1/2: monitor.pbp.on: verified 0xD7 = 0",
                "run guest step 2/2: usb.select: port 2",
                "run guest finished",
            ])
            #expect(rig.store.log.allSatisfy { $0.level == .info })
        }
    }

    // MARK: Failure

    @Test("a failing step aborts: later steps do not run, events and wait both say failed")
    func failingStepAborts() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            let steps = [
                MacroStep(action: .usbSelect, parameters: ["port": 3]),   // fails
                MacroStep(action: .monitorPBPOn),                          // must not run
                MacroStep(action: .notify, parameters: ["text": "never"]),
            ]
            try await rig.macros.save([Macro(id: "abort", name: "Abort", steps: steps)])
            let unreachable = ControllerError.unreachable(URL(string: "http://192.168.1.50:80")!, underlying: "connection refused")
            await rig.controller.fail(with: unreachable)

            let stream = await rig.runner.events
            let handle = try await rig.runner.start(id: "abort")
            let events = try await collect(stream, for: handle)

            #expect(summary(events) == ["started:0/3", "failed:1/3"])
            let failure = try #require(events.last)
            #expect(failure.message == "usb.select: controller unreachable at 192.168.1.50:80: connection refused")

            let waited = await rig.runner.wait(handle)
            #expect(waited == failure)
            #expect(await rig.runner.error(of: handle) == .controller(unreachable))

            #expect(await rig.monitor.writes.isEmpty, "the PBP step after the failure must not run")
            #expect(rig.notified.all.isEmpty)
            #expect(rig.store.state.lastError == "abort: usb.select: controller unreachable at 192.168.1.50:80: connection refused")
            #expect(!rig.store.state.controllerReachable)
            #expect(rig.store.log.last?.level == .error)
        }
    }

    @Test("a failure after some steps keeps the earlier steps' events and effects")
    func failureAfterProgress() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            await rig.controller.fail(with: .timeout)
            let (handle, events) = try await runAndCollect(rig.runner, "guest")

            // Step 1 (PBP on) completed, step 2 (USB) timed out.
            #expect(summary(events) == ["started:0/2", "step:1/2", "failed:2/2"])
            #expect(events.last?.message == "usb.select: controller did not answer in time")
            #expect(rig.store.state.pbp == .on)
            #expect(await rig.runner.error(of: handle) == .controller(.timeout))
        }
    }

    @Test("an unverified PBP write fails the run at that step and the next step does not run")
    func unverifiedFails() async throws {
        try await withTempDirectory { directory in
            let (dualUp, _, bridge) = stuckOffDualUp()
            let rig = Rig(directory: directory, dualUp: dualUp)
            let (handle, events) = try await runAndCollect(rig.runner, "guest")

            #expect(summary(events) == ["started:0/2", "failed:1/2"])
            #expect(events.last?.message == "monitor.pbp.on: unverified: 0xD7 read back 1 (off), expected 0 (on)")
            let error = try #require(await rig.runner.error(of: handle))
            #expect(error.isUnverifiedWrite)
            #expect(await bridge.writes.count == 1)
            #expect(await rig.controller.calls.isEmpty, "usb.select must not run after an unverified PBP write")
            #expect(rig.store.state.pbp == .off, "the store shows what the monitor actually read")
        }
    }

    @Test("a macro that needs the controller fails before any step when there is none")
    func noControllerFailsBeforeAnyStep() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory, withController: false)
            let (handle, events) = try await runAndCollect(rig.runner, "guest")

            #expect(summary(events) == ["started:0/2", "failed:0/2"])
            #expect(events.last?.message.hasPrefix("usb.select: no controller is configured") == true)
            #expect(events.last?.message.contains("SWITCHBOARD_CONTROLLER_URL") == true)
            #expect(await rig.monitor.writes.isEmpty, "PBP must not be switched on and then left without a USB switch")
            #expect(await rig.runner.error(of: handle)?.isControllerUnreachable == true)
        }
    }

    @Test("a macro that needs the monitor fails before any step when there is none")
    func noMonitorFailsBeforeAnyStep() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory, withMonitor: false)
            let (_, events) = try await runAndCollect(rig.runner, "solo")   // usb.select, then monitor.pbp.off

            #expect(summary(events) == ["started:0/2", "failed:0/2"])
            #expect(events.last?.message == "monitor.pbp.off: no monitor is configured")
            #expect(await rig.controller.calls.isEmpty)
        }
    }

    // MARK: Verify

    @Test("verify failures list the mismatching field")
    func verifyFailed() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            try await rig.macros.save([
                Macro(
                    id: "wrong", name: "Wrong",
                    steps: [MacroStep(action: .usbSelect, parameters: ["port": 3])],
                    verify: MacroVerify(pbp: .off, usbPort: 2)
                ),
            ])
            let (handle, events) = try await runAndCollect(rig.runner, "wrong")

            #expect(summary(events) == ["started:0/1", "step:1/1", "failed:1/1"])
            // PBP was never read in this run, so the store has it unknown; USB is on 3, not 2.
            #expect(events.last?.message == "verify failed: pbp: expected off, got unknown; usbPort: expected 2, got 3")
            #expect(await rig.runner.error(of: handle) == .verifyFailed(["pbp: expected off, got unknown", "usbPort: expected 2, got 3"]))
        }
    }

    @Test("verify names only the fields that differ")
    func verifyOneField() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            try await rig.macros.save([
                Macro(
                    id: "half", name: "Half",
                    steps: [MacroStep(action: .usbSelect, parameters: ["port": 3]), MacroStep(action: .monitorRead)],
                    verify: MacroVerify(pbp: .off, usbPort: 2)
                ),
            ])
            let (_, events) = try await runAndCollect(rig.runner, "half")
            #expect(events.last?.message == "verify failed: usbPort: expected 2, got 3")
        }
    }

    @Test("a macro without verify finishes after its last step")
    func noVerify() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            try await rig.macros.save([Macro(id: "plain", name: "Plain", steps: [MacroStep(action: .usbSelect, parameters: ["port": 4])])])
            let (_, events) = try await runAndCollect(rig.runner, "plain")
            #expect(summary(events) == ["started:0/1", "step:1/1", "finished:1/1"])
        }
    }

    // MARK: delay, notify

    @Test("a delay step uses the injected sleeper")
    func delayUsesSleeper() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            try await rig.macros.save([
                Macro(id: "pause", name: "Pause", steps: [MacroStep(action: .delay, parameters: ["ms": 1500]), MacroStep(action: .delay, parameters: ["ms": 250])]),
            ])
            let (_, events) = try await runAndCollect(rig.runner, "pause")
            #expect(summary(events) == ["started:0/2", "step:1/2", "step:2/2", "finished:2/2"])
            #expect(rig.sleeper.durations == [.milliseconds(1500), .milliseconds(250)])
        }
    }

    @Test("a notify step reaches the notify closure")
    func notifyReachesClosure() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            try await rig.macros.save([Macro(id: "tell", name: "Tell", steps: [MacroStep(action: .notify, parameters: ["text": "Guest mode"])])])
            let (_, events) = try await runAndCollect(rig.runner, "tell")
            #expect(events.map(\.message) == ["", "notify: Guest mode", "ok"])
            #expect(rig.notified.all == ["Guest mode"])
        }
    }

    // MARK: Single actions

    @Test("an action id runs as a one-step run of kind action")
    func singleAction() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            let (handle, events) = try await runAndCollect(rig.runner, "usb.select", ["port": 3])

            #expect(handle.kind == .action)
            #expect(handle.id == "usb.select")
            #expect(summary(events) == ["started:0/1", "step:1/1", "finished:1/1"])
            #expect(events.allSatisfy { $0.kind == .action })
            #expect(rig.store.state.usbPort == 3)
        }
    }

    @Test("a parameter-free action runs without a body")
    func parameterFreeAction() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory, monitor: FakeMonitor(pbp: 0))
            let (_, events) = try await runAndCollect(rig.runner, "monitor.read")
            #expect(events.last?.status == .finished)
            #expect(rig.store.state.pbp == .on)
        }
    }

    @Test("a macro id wins over an action id, and macros ignore the parameters passed")
    func macroWins() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            try await rig.macros.save([Macro(id: "usb.select", name: "Shadow", steps: [MacroStep(action: .notify, parameters: ["text": "macro ran"])])])
            let (handle, events) = try await runAndCollect(rig.runner, "usb.select", ["port": 3, "junk": true])

            #expect(handle.kind == .macro)
            #expect(events.last?.status == .finished)
            #expect(rig.notified.all == ["macro ran"])
            #expect(await rig.controller.calls.isEmpty)
        }
    }

    @Test("an action that fails ends the run with failed, and the error is kept")
    func singleActionFails() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            await rig.controller.fail(with: .httpStatus(500, body: "boom"))
            let (handle, events) = try await runAndCollect(rig.runner, "hdmi.select", ["display": "lg4k", "input": 2])
            #expect(summary(events) == ["started:0/1", "failed:1/1"])
            #expect(await rig.runner.error(of: handle) == .controller(.httpStatus(500, body: "boom")))
        }
    }

    // MARK: Refusals

    @Test("an unknown id throws unknownID and starts nothing")
    func unknownID() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            let stream = await rig.runner.events
            await #expect(throws: ActionError.unknownID("nope")) { try await rig.runner.start(id: "nope") }
            #expect(await rig.runner.currentRun == nil)
            #expect(await rig.runner.activity == RunActivity(isRunning: false, started: 0))

            // And nothing was published: the next run's first event is its own `started`.
            let handle = try await rig.runner.start(id: "usb.select", parameters: ["port": 1])
            let events = try await collect(stream, for: handle)
            #expect(events.first?.status == .started)
        }
    }

    @Test("an action with a missing or bad parameter is refused at start, before any event")
    func parameterErrorsAtStart() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            await #expect(throws: ActionError.missingParameter("port")) { try await rig.runner.start(id: "usb.select") }
            await #expect(throws: ActionError.invalidParameter("ms", "must be 0 to 60000, got 90000")) {
                try await rig.runner.start(id: "delay", parameters: ["ms": 90000])
            }
            #expect(await rig.runner.activity.started == 0)
            #expect(await rig.controller.calls.isEmpty)
        }
    }

    @Test("a second start while a run is in progress throws busy with the running run's id")
    func busy() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            let gate = Gate()
            await rig.controller.hold(at: gate)

            let stream = await rig.runner.events
            let first = try await rig.runner.start(id: "guest")
            #expect(await rig.runner.currentRun == first)
            #expect(await rig.runner.activity == RunActivity(isRunning: true, started: 1))

            // Step 1 (PBP on) finishes; step 2 (usb.select) then waits at the gate.
            var seen: [RunEvent] = []
            for await event in stream where event.runId == first.runId {
                seen.append(event)
                if event.status == .step { break }
            }
            #expect(summary(seen) == ["started:0/2", "step:1/2"])

            await #expect(throws: ActionError.busy(runID: first.runId)) { try await rig.runner.start(id: "solo") }
            await #expect(throws: ActionError.busy(runID: first.runId)) { try await rig.runner.start(id: "delay", parameters: ["ms": 1]) }
            #expect(await rig.runner.activity.started == 1, "refused starts are not runs")

            await gate.release()
            let terminal = await rig.runner.wait(first)
            #expect(terminal.status == .finished)

            // The slot is free again, and the one that was refused can now run.
            #expect(await rig.runner.currentRun == nil)
            let (_, events) = try await runAndCollect(rig.runner, "solo")
            #expect(events.last?.status == .finished)
        }
    }

    @Test("the slot is free as soon as the terminal event is published")
    func slotFreeAtTerminalEvent() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            for _ in 0..<5 {
                // Start the next run the instant the previous one's terminal event arrives.
                _ = try await runAndCollect(rig.runner, "usb.select", ["port": 2])
            }
            #expect(await rig.runner.activity == RunActivity(isRunning: false, started: 5))
        }
    }

    @Test("concurrent starts: exactly one wins")
    func concurrentStarts() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            let gate = Gate()
            await rig.controller.hold(at: gate)

            let runner = rig.runner
            let outcomes = await withTaskGroup(of: String.self) { group in
                for _ in 0..<6 {
                    group.addTask {
                        do {
                            _ = try await runner.start(id: "usb.select", parameters: ["port": 2])
                            return "started"
                        } catch let error as ActionError {
                            return error.isBusy ? "busy" : "other"
                        } catch {
                            return "other"
                        }
                    }
                }
                var results: [String] = []
                for await result in group { results.append(result) }
                return results
            }
            #expect(outcomes.filter { $0 == "started" }.count == 1)
            #expect(outcomes.filter { $0 == "busy" }.count == 5)

            await gate.release()
            let current = await runner.currentRun
            if let current { _ = await runner.wait(current) }
        }
    }

    // MARK: Events

    @Test("events fan out to every subscriber, each seeing the whole run")
    func fanOut() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            let a = await rig.runner.events
            let b = await rig.runner.events
            #expect(await rig.runner.subscriberCount == 2)

            let handle = try await rig.runner.start(id: "guest")
            let first = try await collect(a, for: handle)
            let second = try await collect(b, for: handle)
            #expect(first == second)
            #expect(summary(first) == ["started:0/2", "step:1/2", "step:2/2", "finished:2/2"])
        }
    }

    @Test("a subscriber that goes away is dropped")
    func subscriberDropped() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            do {
                let stream = await rig.runner.events
                #expect(await rig.runner.subscriberCount == 1)
                withExtendedLifetime(stream) {}
            }
            for _ in 0..<100 where await rig.runner.subscriberCount > 0 { await Task.yield() }
            #expect(await rig.runner.subscriberCount == 0)
            _ = try await runAndCollect(rig.runner, "usb.select", ["port": 1])   // publishing with nobody listening is fine
        }
    }

    @Test("a late subscriber sees only the runs that start after it subscribed")
    func lateSubscriber() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            let first = try await rig.runner.start(id: "usb.select", parameters: ["port": 2])
            _ = await rig.runner.wait(first)

            let stream = await rig.runner.events
            let second = try await rig.runner.start(id: "usb.select", parameters: ["port": 1])
            let events = try await collect(stream, for: second)
            #expect(events.first?.status == .started)
            #expect(events.allSatisfy { $0.runId == second.runId })
        }
    }

    @Test("run ids are unique per run")
    func uniqueRunIDs() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            var ids: Set<String> = []
            for _ in 0..<4 {
                let (handle, _) = try await runAndCollect(rig.runner, "usb.select", ["port": 1])
                ids.insert(handle.runId)
            }
            #expect(ids.count == 4)
        }
    }

    // MARK: Store interplay

    @Test("a failed run sets lastError and a later successful one clears it")
    func lastErrorLifecycle() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            await rig.controller.fail(with: .timeout)
            _ = try await runAndCollect(rig.runner, "usb.select", ["port": 2])
            #expect(rig.store.state.lastError == "usb.select: controller did not answer in time")

            await rig.controller.fail(with: nil)
            _ = try await runAndCollect(rig.runner, "usb.select", ["port": 2])
            #expect(rig.store.state.lastError == nil)
        }
    }

    @Test("a broken macros.json does not hide the plain actions, but a macro id reports the file error")
    func brokenMacroFile() async throws {
        try await withTempDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("{ broken".utf8).write(to: directory.appending(path: "macros.json"))
            let rig = Rig(directory: directory)

            let (_, events) = try await runAndCollect(rig.runner, "usb.select", ["port": 2])
            #expect(events.last?.status == .finished)

            await #expect(throws: MacroStoreError.self) { try await rig.runner.start(id: "guest") }
        }
    }

    // MARK: execute

    @Test("execute streams a run to a callback and reports how it ended")
    func executeSucceeds() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            let lines = Recorder<String>()
            let report = try await rig.runner.execute(id: "guest") { lines.record($0.line) }

            #expect(report.succeeded)
            #expect(report.error == nil)
            #expect(report.terminal.status == .finished)
            #expect(report.handle.id == "guest")
            #expect(lines.all == [
                "started guest (2 steps)",
                "step 1/2: monitor.pbp.on: verified 0xD7 = 0",
                "step 2/2: usb.select: port 2",
                "finished guest: ok",
            ])
        }
    }

    @Test("execute reports the error of a failed run")
    func executeFails() async throws {
        try await withTempDirectory { directory in
            let (dualUp, _, _) = stuckOffDualUp()
            let rig = Rig(directory: directory, dualUp: dualUp)
            let lines = Recorder<String>()
            let report = try await rig.runner.execute(id: "guest") { lines.record($0.line) }

            #expect(!report.succeeded)
            #expect(report.error?.isUnverifiedWrite == true)
            #expect(lines.all.last == "failed guest at step 1/2: monitor.pbp.on: unverified: 0xD7 read back 1 (off), expected 0 (on)")
        }
    }

    @Test("execute throws what start throws")
    func executeThrows() async throws {
        try await withTempDirectory { directory in
            let rig = Rig(directory: directory)
            await #expect(throws: ActionError.unknownID("nope")) { try await rig.runner.execute(id: "nope") { _ in } }
            #expect(await rig.runner.currentRun == nil)
        }
    }
}

@Suite("RunEvent and RunHandle")
struct RunEventTests {
    @Test("a run event encodes with exactly the keys in docs/API.md")
    func wireShape() throws {
        let event = RunEvent(runId: "7f3c", id: "guest", kind: .macro, status: .step, step: 1, stepCount: 2, message: "monitor.pbp.on: verified 0xD7 = 0")
        #expect(try jsonTree(event) == [
            "runId": "7f3c", "id": "guest", "kind": "macro", "status": "step", "step": 1, "stepCount": 2,
            "message": "monitor.pbp.on: verified 0xD7 = 0",
        ])
    }

    @Test("the example events in docs/API.md decode")
    func decodesAPIExamples() throws {
        let examples = [
            #"{"runId":"7f3c…","id":"guest","kind":"macro","status":"started","step":0,"stepCount":2,"message":""}"#,
            #"{"runId":"7f3c…","id":"guest","kind":"macro","status":"step","step":1,"stepCount":2,"message":"monitor.pbp.on: verified 0xD7 = 0"}"#,
            #"{"runId":"7f3c…","id":"guest","kind":"macro","status":"finished","step":2,"stepCount":2,"message":"ok"}"#,
        ]
        let events = try examples.map { try JSONDecoder().decode(RunEvent.self, from: Data($0.utf8)) }
        #expect(events.map(\.status) == [.started, .step, .finished])
        #expect(events.map(\.isTerminal) == [false, false, true])
        for (event, text) in zip(events, examples) {
            #expect(try jsonTree(event) == (try jsonTree(text)))
        }
    }

    @Test("the 202 body is runId, id and kind")
    func handleShape() throws {
        let handle = RunHandle(runId: "7f3c", id: "guest", kind: .macro)
        #expect(try jsonTree(handle) == ["runId": "7f3c", "id": "guest", "kind": "macro"])
        #expect(try jsonTree(RunHandle(runId: "r", id: "usb.select", kind: .action))["kind"] == "action")
    }

    @Test("lines read like a progress report")
    func lines() {
        func event(_ status: RunEvent.Status, step: Int, count: Int = 2, message: String = "") -> RunEvent {
            RunEvent(runId: "r", id: "guest", kind: .macro, status: status, step: step, stepCount: count, message: message)
        }
        #expect(event(.started, step: 0).line == "started guest (2 steps)")
        #expect(event(.started, step: 0, count: 1).line == "started guest (1 step)")
        #expect(event(.step, step: 1, message: "usb.select: port 2").line == "step 1/2: usb.select: port 2")
        #expect(event(.finished, step: 2, message: "ok").line == "finished guest: ok")
        #expect(event(.failed, step: 1, message: "boom").line == "failed guest at step 1/2: boom")
        #expect(event(.failed, step: 0, message: "no controller").line == "failed guest before step 1: no controller")
    }
}
