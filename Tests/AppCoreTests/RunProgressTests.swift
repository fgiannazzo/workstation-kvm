import Actions
import AppCore
import Foundation
import Testing

private func event(
    _ status: RunEvent.Status,
    step: Int,
    of count: Int = 2,
    message: String = "",
    id: String = "guest",
    run: String = "run-1"
) -> RunEvent {
    RunEvent(runId: run, id: id, kind: .macro, status: status, step: step, stepCount: count, message: message)
}

@Suite("RunProgress")
struct RunProgressTests {
    @Test("nothing has run yet")
    func initial() {
        let progress = RunProgress()
        #expect(!progress.isRunning)
        #expect(progress.currentStep == 0)
        #expect(progress.stepCount == 0)
        #expect(progress.lastMessage == "")
        #expect(progress.lastOutcome == .none)
        #expect(progress.statusLine == "")
        #expect(progress.fraction == 0)
    }

    @Test("started, step, step, finished")
    func finishedRun() {
        var progress = RunProgress()

        progress.apply(event(.started, step: 0))
        #expect(progress.isRunning)
        #expect(progress.currentStep == 0)
        #expect(progress.stepCount == 2)
        #expect(progress.lastOutcome == .none)
        #expect(progress.statusLine == "Running guest, step 1 of 2")

        progress.apply(event(.step, step: 1, message: "monitor.pbp.on: verified 0xD7 = 0"))
        #expect(progress.isRunning)
        #expect(progress.currentStep == 1)
        #expect(progress.lastMessage == "monitor.pbp.on: verified 0xD7 = 0")
        #expect(progress.fraction == 0.5)
        #expect(progress.statusLine == "Running guest, step 2 of 2")

        progress.apply(event(.step, step: 2, message: "usb.select: port 2"))
        progress.apply(event(.finished, step: 2, message: "ok"))
        #expect(!progress.isRunning)
        #expect(progress.currentStep == 2)
        #expect(progress.stepCount == 2)
        #expect(progress.lastMessage == "ok")
        #expect(progress.lastOutcome == .finished)
        #expect(progress.fraction == 1)
        #expect(progress.statusLine == "Finished guest")
    }

    @Test("started, failed: the step that failed and the reason are kept")
    func failedRun() {
        var progress = RunProgress()
        progress.apply(event(.started, step: 0))
        progress.apply(event(.failed, step: 1, message: "monitor.pbp.on: unverified: 0xD7 read back 1 (off), expected 0 (on)"))

        #expect(!progress.isRunning)
        #expect(progress.currentStep == 1)
        #expect(progress.stepCount == 2)
        #expect(progress.lastOutcome == .failed)
        #expect(progress.lastMessage == "monitor.pbp.on: unverified: 0xD7 read back 1 (off), expected 0 (on)")
        #expect(progress.statusLine == "Failed guest: monitor.pbp.on: unverified: 0xD7 read back 1 (off), expected 0 (on)")
    }

    @Test("a run that fails before its first step reports step 0")
    func failedBeforeFirstStep() {
        var progress = RunProgress()
        progress.apply(event(.started, step: 0))
        progress.apply(event(.failed, step: 0, message: "usb.select: no controller is configured"))
        #expect(progress.currentStep == 0)
        #expect(progress.lastOutcome == .failed)
    }

    @Test("a new run clears the previous outcome and message")
    func newRunResets() {
        var progress = RunProgress()
        progress.apply(event(.started, step: 0))
        progress.apply(event(.failed, step: 1, message: "boom"))

        progress.apply(event(.started, step: 0, of: 1, id: "solo", run: "run-2"))
        #expect(progress.isRunning)
        #expect(progress.id == "solo")
        #expect(progress.stepCount == 1)
        #expect(progress.lastOutcome == .none)
        #expect(progress.lastMessage == "")
    }

    @Test("events of another run than the one in progress are ignored")
    func strayEvents() {
        var progress = RunProgress()
        progress.apply(event(.started, step: 0))
        progress.apply(event(.step, step: 1, message: "other", run: "run-9"))
        progress.apply(event(.finished, step: 2, message: "ok", run: "run-9"))

        #expect(progress.isRunning)
        #expect(progress.currentStep == 0)
        #expect(progress.lastOutcome == .none)
    }

    @Test("a step event with no run in progress changes nothing")
    func strayStep() {
        var progress = RunProgress()
        progress.apply(event(.step, step: 1, message: "late"))
        #expect(progress == RunProgress())
    }

    @Test("a rejected run is shown as a failure with no steps")
    func rejected() {
        var progress = RunProgress()
        progress.apply(event(.started, step: 0))
        progress.apply(event(.finished, step: 2, message: "ok"))

        progress.reject(id: "nope", message: "unknown action or macro \"nope\"")
        #expect(!progress.isRunning)
        #expect(progress.lastOutcome == .failed)
        #expect(progress.stepCount == 0)
        #expect(progress.statusLine == "Failed nope: unknown action or macro \"nope\"")
    }

    @Test("a single action is a one-step run")
    func singleAction() {
        var progress = RunProgress()
        progress.apply(RunEvent(runId: "a", id: "usb.select", kind: .action, status: .started, step: 0, stepCount: 1, message: ""))
        #expect(progress.statusLine == "Running usb.select, step 1 of 1")
        progress.apply(RunEvent(runId: "a", id: "usb.select", kind: .action, status: .finished, step: 1, stepCount: 1, message: "ok"))
        #expect(progress.statusLine == "Finished usb.select")
    }
}
