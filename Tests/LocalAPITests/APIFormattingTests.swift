import Actions
import Foundation
import LocalAPI
import SwitchboardCore
import Testing

@Suite("State and event text")
struct APIFormattingTests {
    private let known = SwitchboardState(
        pbp: .on,
        mainInput: .hdmi2,
        usbPort: 2,
        hdmiInput: [.dualup: 1, .lg4k: 2],
        controllerReachable: true,
        dualUpReachable: true,
        lastError: "boom",
        updatedAt: Date(timeIntervalSince1970: 1_791_749_703.12)
    )

    @Test("state lines for a state that is fully known")
    func knownState() {
        #expect(known.summaryLines == [
            "pbp: on",
            "main input: HDMI 2",
            "usb: port 2",
            "hdmi: dualup 1  lg4k 2  samsung unknown",
            "controller: reachable",
            "monitor: reachable",
            "last error: boom",
            "updated: 2026-10-11T20:15:03.120Z",
        ])
    }

    @Test("a state nothing has read says unknown everywhere, never a default")
    func unknownState() {
        #expect(SwitchboardState().summaryLines == [
            "pbp: unknown",
            "main input: unknown",
            "usb: unknown",
            "hdmi: dualup unknown  lg4k unknown  samsung unknown",
            "controller: not reachable",
            "monitor: not reachable",
            "last error: none",
            "updated: never",
        ])
    }

    @Test("PBP off and HDMI 1 read as such")
    func offAndHDMI1() {
        let state = SwitchboardState(pbp: .off, mainInput: .hdmi1)
        #expect(state.summaryLines[0] == "pbp: off")
        #expect(state.summaryLines[1] == "main input: HDMI 1")
    }

    @Test("an event line carries the fields a person scans for")
    func eventLine() {
        #expect(known.eventLine == "state  pbp=on main=hdmi2 usb=2 hdmi=dualup:1,lg4k:2 controller=up monitor=up error=boom")
        #expect(SwitchboardState().eventLine == "state  pbp=unknown main=unknown usb=? hdmi=? controller=down monitor=down error=none")
    }

    @Test("run events print as RunEvent.line, behind a run tag")
    func runLine() {
        let event = RunEvent(runId: "r", id: "guest", kind: .macro, status: .step, step: 1, stepCount: 2, message: "monitor.pbp.on: verified 0xD7 = 0")
        #expect(APIEvent.run(event).line(json: false) == "run    step 1/2: monitor.pbp.on: verified 0xD7 = 0")
        #expect(APIEvent.state(known).line(json: false) == known.eventLine)
    }

    @Test("--json lines are one object with the event name and its data, keys sorted")
    func jsonLines() throws {
        let event = RunEvent(runId: "r", id: "guest", kind: .macro, status: .started, step: 0, stepCount: 2, message: "")
        let run = try #require(APIEvent.run(event).line(json: true))
        #expect(run == #"{"data":{"id":"guest","kind":"macro","message":"","runId":"r","status":"started","step":0,"stepCount":2},"event":"run"}"#)

        let state = try #require(APIEvent.state(known).line(json: true))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(state.utf8)) as? [String: Any])
        #expect(object["event"] as? String == "state")
        let data = try #require(object["data"] as? [String: Any])
        #expect(data["usbPort"] as? Int == 2)
        #expect(data["updatedAt"] as? String == "2026-10-11T20:15:03.120Z")
        #expect(!state.contains("\n"))
    }
}
