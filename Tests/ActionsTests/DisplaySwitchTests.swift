import Actions
import DDCKit
import Devices
import Foundation
import StateStore
import SwitchboardCore
import Testing

private let lg4k = ManagedDisplay(name: "LG HDR 4K", uuid: "UUID-4K", serial: "302NTCZ1U003")
private let samsung = ManagedDisplay(name: "Odyssey G80SD", uuid: "UUID-G80", serial: "H1AK500000")
private let dualUp = ManagedDisplay(name: "LG SDQHD", uuid: "UUID-DUALUP", serial: "301NTQDF4860")
private let desk = [lg4k, samsung, dualUp]

private func behaviour(_ change: (inout FakeDisplayConnector.Behaviour) -> Void) -> FakeDisplayConnector.Behaviour {
    var behaviour = FakeDisplayConnector.Behaviour()
    change(&behaviour)
    return behaviour
}

@Suite("DisplaySwitch")
struct DisplaySwitchTests {
    @Test("turnOff disconnects every listed display and reads them back; turnOn connects them all again")
    func offAndOn() async throws {
        let connector = FakeDisplayConnector(displays: desk)
        let sleeper = RecordingSleeper()
        let displays = DisplaySwitch(connector: connector, sleep: sleeper.sleeper)
        #expect(await displays.read() == .on)

        #expect(try await displays.turnOff() == ["LG HDR 4K", "Odyssey G80SD", "LG SDQHD"])
        #expect(await connector.connected == ["UUID-4K": false, "UUID-G80": false, "UUID-DUALUP": false])
        #expect(await displays.read() == .off)
        #expect(sleeper.durations.isEmpty, "every display read back at once, no waiting")

        #expect(try await displays.turnOn() == ["LG HDR 4K", "Odyssey G80SD", "LG SDQHD"])
        #expect(await connector.requests.contains("connectAll"))
        #expect(await displays.read() == .on)
    }

    @Test("with displaysToTurnOff only the named displays switch, one by one")
    func selectors() async throws {
        let connector = FakeDisplayConnector(displays: desk)
        let displays = DisplaySwitch(connector: connector, selectors: ["301ntqdf4860", " Odyssey G80SD ", ""], sleep: instant)
        #expect(try await displays.turnOff() == ["Odyssey G80SD", "LG SDQHD"])
        #expect(await connector.connected == ["UUID-4K": true, "UUID-G80": false, "UUID-DUALUP": false])
        #expect(await displays.read() == .off, "the state covers the named displays only")

        #expect(try await displays.turnOn() == ["Odyssey G80SD", "LG SDQHD"])
        let requests = await connector.requests
        #expect(!requests.contains("connectAll"))
        #expect(requests.contains("set UUID-G80 on"))
        #expect(requests.contains("set UUID-DUALUP on"))
        #expect(!requests.contains("set UUID-4K off"))
    }

    @Test("a change that takes a few reads to show is waited for, settle apart")
    func waitsForTheChange() async throws {
        let connector = FakeDisplayConnector(displays: [dualUp], behaviour: behaviour { $0.settleReads = 3 })
        let sleeper = RecordingSleeper()
        let displays = DisplaySwitch(connector: connector, sleep: sleeper.sleeper, settle: .milliseconds(500), attempts: 10)
        _ = try await displays.turnOff()
        #expect(sleeper.durations == [.milliseconds(500), .milliseconds(500), .milliseconds(500)])
    }

    @Test("a display that never changes fails the switch, naming it and what it read")
    func unverified() async throws {
        let connector = FakeDisplayConnector(displays: [lg4k, dualUp], behaviour: behaviour { $0.ignoredUUIDs = ["UUID-DUALUP"] })
        let sleeper = RecordingSleeper()
        let displays = DisplaySwitch(connector: connector, sleep: sleeper.sleeper, attempts: 4)
        await #expect(throws: ActionError.verifyFailed(["LG SDQHD: connected, expected disconnected"])) { try await displays.turnOff() }
        #expect(sleeper.durations.count == 3, "attempts reads, a settle between each")
        #expect(await displays.read() == .mixed)
    }

    @Test("a refused request is reported and the others still switch (BetterDisplay keeps the last display)")
    func refusedLast() async throws {
        let connector = FakeDisplayConnector(displays: desk, behaviour: behaviour { $0.refusesLastDisconnect = true })
        let displays = DisplaySwitch(connector: connector, sleep: instant)
        await #expect(throws: ActionError.verifyFailed(["LG SDQHD: BetterDisplay set -UUID=UUID-DUALUP failed (exit 1: Failed.)"])) {
            try await displays.turnOff()
        }
        #expect(await connector.connected == ["UUID-4K": false, "UUID-G80": false, "UUID-DUALUP": true])
        #expect(await displays.read() == .mixed)
    }

    @Test("displays that drop out of the list while off still count as off, and come back on")
    func unlisted() async throws {
        let connector = FakeDisplayConnector(displays: desk, behaviour: behaviour { $0.unlistsDisconnected = true })
        let displays = DisplaySwitch(connector: connector, sleep: instant)
        _ = try await displays.turnOff()
        #expect(try await connector.displays().isEmpty)
        #expect(await displays.read() == .off)
        #expect(try await displays.turnOn().count == 3)
        #expect(await displays.read() == .on)
    }

    @Test("a display that is already off is not asked again")
    func alreadyOff() async throws {
        let connector = FakeDisplayConnector(displays: [lg4k, dualUp])
        try await connector.setConnected(dualUp, false)
        let displays = DisplaySwitch(connector: connector, sleep: instant)
        _ = try await displays.turnOff()
        #expect(await connector.requests.filter { $0.hasPrefix("set") } == ["set UUID-DUALUP off", "set UUID-4K off"])
    }

    @Test("nothing to switch is an error that says why")
    func nothingToSwitch() async throws {
        let none = DisplaySwitch(connector: FakeDisplayConnector(displays: []), sleep: instant)
        await #expect(throws: ActionError.displaysUnavailable("nothing to switch: no physical displays are listed")) { try await none.turnOff() }
        #expect(await none.read() == .unknown)

        let typo = DisplaySwitch(connector: FakeDisplayConnector(displays: desk), selectors: ["LG SDQHX"], sleep: instant)
        await #expect(throws: ActionError.displaysUnavailable("nothing to switch: no display matches displaysToTurnOff (LG SDQHX)")) {
            try await typo.turnOn()
        }
    }
}

@MainActor
@Suite("displays.off and displays.on")
struct DisplayActionTests {
    private let registry = ActionRegistry()

    @Test("run through the registry, report the displays and leave the read-back in the store")
    func throughRegistry() async throws {
        let store = StateStore()
        let connector = FakeDisplayConnector(displays: [lg4k, dualUp])
        let context = ActionContext(dualUp: nil, controller: nil, displays: DisplaySwitch(connector: connector, sleep: instant), store: store)

        #expect(try await registry.run(.displaysOff, parameters: [:], context: context) == "displays.off: disconnected LG HDR 4K, LG SDQHD")
        #expect(store.state.displays == .off)
        #expect(try await registry.run(.displaysOn, parameters: [:], context: context) == "displays.on: connected LG HDR 4K, LG SDQHD")
        #expect(store.state.displays == .on)
    }

    @Test("a failed switch still records what was read")
    func failureIsRecorded() async throws {
        let store = StateStore()
        let connector = FakeDisplayConnector(displays: [lg4k, dualUp], behaviour: behaviour { $0.failingUUIDs = ["UUID-4K"] })
        let context = ActionContext(dualUp: nil, controller: nil, displays: DisplaySwitch(connector: connector, sleep: instant), store: store)
        await #expect(throws: ActionError.self) { try await registry.run(.displaysOff, parameters: [:], context: context) }
        #expect(store.state.displays == .mixed)
    }

    @Test("without BetterDisplay both actions say what is missing and touch nothing")
    func notConfigured() async throws {
        let store = StateStore()
        let context = ActionContext(dualUp: nil, controller: nil, store: store)
        for id in [ActionID.displaysOff, .displaysOn] {
            await #expect(throws: ActionError.displaysNotConfigured) { try await registry.run(id, parameters: [:], context: context) }
        }
        #expect(store.state.updatedAt == .distantPast)
        #expect(ActionError.displaysNotConfigured.description.contains("BetterDisplay was not found"))
        await #expect(throws: ActionError.invalidParameter("port", "displays.off has no such parameter")) {
            try await registry.run(.displaysOff, parameters: ["port": 1], context: context)
        }
    }

    @Test("the refresher reads the displays and logs a change")
    func refresher() async throws {
        let store = StateStore()
        let connector = FakeDisplayConnector(displays: [dualUp])
        let refresher = StateRefresher(dualUp: nil, controller: nil, displays: DisplaySwitch(connector: connector, sleep: instant), store: store, interval: .seconds(30), sleep: instant)
        await refresher.refresh()
        #expect(store.state.displays == .on)
        #expect(store.log.map(\.message) == ["displays on"])
        await refresher.refresh()
        #expect(store.log.count == 1, "no change, no log line")
    }
}
