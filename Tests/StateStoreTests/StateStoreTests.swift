import Foundation
import os
import StateStore
import SwitchboardCore
import Testing

/// A clock the test moves by hand, for `updatedAt` and log dates.
final class TestClock: Sendable {
    private let current: OSAllocatedUnfairLock<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = OSAllocatedUnfairLock(initialState: start)
    }

    var now: Date { current.withLock { $0 } }

    func advance(by seconds: TimeInterval = 1) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

private let briefState = ControllerState(
    hdmi: [.dualup: 1, .lg4k: 2, .samsung: 1],
    usb: .init(port: 2, source: "aten"),
    uptime: 123
)

@MainActor
@Suite("StateStore")
struct StateStoreTests {
    private func makeStore() -> (StateStore, TestClock) {
        let clock = TestClock()
        return (StateStore(now: { clock.now }), clock)
    }

    @Test("a fresh store claims nothing")
    func fresh() {
        let (store, _) = makeStore()
        #expect(store.state == SwitchboardState())
        #expect(store.state.pbp == .unknown)
        #expect(store.state.usbPort == nil)
        #expect(store.state.updatedAt == .distantPast)
        #expect(store.log.isEmpty)
    }

    @Test("applyMonitor sets PBP, main input and reachability")
    func applyMonitor() {
        let (store, _) = makeStore()
        store.applyMonitor(pbp: .on, mainInput: .hdmi2, reachable: true)
        #expect(store.state.pbp == .on)
        #expect(store.state.mainInput == .hdmi2)
        #expect(store.state.dualUpReachable)

        store.applyMonitor(pbp: .unknown, mainInput: .unknown, reachable: false)
        #expect(store.state.pbp == .unknown)
        #expect(store.state.mainInput == .unknown)
        #expect(!store.state.dualUpReachable)
    }

    @Test("apply(controller) sets HDMI inputs and the USB port, and marks the controller reachable")
    func applyController() {
        let (store, _) = makeStore()
        store.applyMonitor(pbp: .on, mainInput: .hdmi1, reachable: true)
        store.apply(briefState)
        #expect(store.state.hdmiInput == [.dualup: 1, .lg4k: 2, .samsung: 1])
        #expect(store.state.usbPort == 2)
        #expect(store.state.controllerReachable)
        // The controller does not touch the monitor's fields.
        #expect(store.state.pbp == .on)
        #expect(store.state.dualUpReachable)
    }

    @Test("reachability flags and the last error are set independently")
    func flagsAndError() {
        let (store, _) = makeStore()
        store.setControllerReachable(true)
        store.setDualUpReachable(true)
        store.setLastError("boom")
        #expect(store.state.controllerReachable)
        #expect(store.state.dualUpReachable)
        #expect(store.state.lastError == "boom")

        store.setControllerReachable(false)
        store.setLastError(nil)
        #expect(!store.state.controllerReachable)
        #expect(store.state.dualUpReachable)
        #expect(store.state.lastError == nil)
    }

    @Test("every mutation sets updatedAt from the clock")
    func updatedAt() {
        let (store, clock) = makeStore()
        let mutations: [(String, @MainActor (StateStore) -> Void)] = [
            ("applyMonitor", { $0.applyMonitor(pbp: .off, mainInput: .hdmi1, reachable: true) }),
            ("apply(controller)", { $0.apply(briefState) }),
            ("setControllerReachable", { $0.setControllerReachable(false) }),
            ("setDualUpReachable", { $0.setDualUpReachable(false) }),
            ("setLastError", { $0.setLastError("x") }),
        ]
        var previous = store.state.updatedAt
        for (name, mutate) in mutations {
            clock.advance(by: 5)
            mutate(store)
            #expect(store.state.updatedAt == clock.now, "\(name) must stamp updatedAt")
            #expect(store.state.updatedAt > previous)
            previous = store.state.updatedAt
        }
    }

    @Test("a mutation that changes nothing still stamps updatedAt")
    func updatedAtWithoutChange() {
        let (store, clock) = makeStore()
        store.setLastError(nil)
        let first = store.state.updatedAt
        clock.advance(by: 30)
        store.setLastError(nil)
        #expect(store.state.updatedAt == first.addingTimeInterval(30))
    }

    // MARK: Log

    @Test("log appends entries with the level, message and clock date")
    func logEntries() {
        let (store, clock) = makeStore()
        store.log(.info, "one")
        clock.advance(by: 2)
        store.log(.error, "two")
        #expect(store.log.map(\.message) == ["one", "two"])
        #expect(store.log.map(\.level) == [.info, .error])
        #expect(store.log[1].date == store.log[0].date.addingTimeInterval(2))
        #expect(Set(store.log.map(\.id)).count == 2)
    }

    @Test("the log is a ring buffer of 500 entries: the oldest fall off")
    func logRingBuffer() {
        let (store, _) = makeStore()
        #expect(StateStore.logCapacity == 500)
        for number in 0..<500 { store.log(.debug, "m\(number)") }
        #expect(store.log.count == 500)
        #expect(store.log.first?.message == "m0")

        store.log(.debug, "m500")
        #expect(store.log.count == 500)
        #expect(store.log.first?.message == "m1")
        #expect(store.log.last?.message == "m500")

        for number in 501..<1200 { store.log(.debug, "m\(number)") }
        #expect(store.log.count == 500)
        #expect(store.log.first?.message == "m700")
        #expect(store.log.last?.message == "m1199")
        #expect(store.log.map(\.message) == (700..<1200).map { "m\($0)" })
    }

    @Test("logging does not change the state or publish")
    func logLeavesStateAlone() async {
        let (store, _) = makeStore()
        var iterator = store.changes.makeAsyncIterator()
        _ = await iterator.next()   // the current state
        let before = store.state
        store.log(.warning, "careful")
        #expect(store.state == before)
        store.setLastError("e")
        // The next thing published is the mutation, not the log line.
        #expect(await iterator.next()?.lastError == "e")
    }

    // MARK: changes

    @Test("changes delivers the current state first, then every update")
    func changesStream() async {
        let (store, _) = makeStore()
        store.applyMonitor(pbp: .off, mainInput: .hdmi1, reachable: true)

        var iterator = store.changes.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == store.state)
        #expect(first?.pbp == .off)

        store.applyMonitor(pbp: .on, mainInput: .hdmi1, reachable: true)
        store.apply(briefState)
        store.setLastError("x")

        let second = await iterator.next()
        let third = await iterator.next()
        let fourth = await iterator.next()
        #expect(second?.pbp == .on)
        #expect(third?.usbPort == 2)
        #expect(fourth?.lastError == "x")
        #expect(fourth == store.state)
    }

    @Test("a subscriber of a fresh store still gets the (unknown) current state")
    func changesOnFreshStore() async {
        let (store, _) = makeStore()
        var iterator = store.changes.makeAsyncIterator()
        #expect(await iterator.next() == SwitchboardState())
    }

    @Test("any number of subscribers each see every update")
    func fanOut() async {
        let (store, _) = makeStore()
        var a = store.changes.makeAsyncIterator()
        var b = store.changes.makeAsyncIterator()
        var c = store.changes.makeAsyncIterator()
        #expect(store.subscriberCount == 3)

        store.setControllerReachable(true)
        for _ in 0..<2 {   // the current state, then the update
            _ = await a.next()
            _ = await b.next()
        }
        let last = await c.next()
        let update = await c.next()
        #expect(last?.controllerReachable == false)
        #expect(update?.controllerReachable == true)
        #expect(store.state.controllerReachable)
    }

    @Test("a subscriber that joins late starts from the state at that moment")
    func lateSubscriber() async {
        let (store, _) = makeStore()
        store.setLastError("before")
        var iterator = store.changes.makeAsyncIterator()
        #expect(await iterator.next()?.lastError == "before")
        store.setLastError("after")
        #expect(await iterator.next()?.lastError == "after")
    }

    @Test("a subscriber that goes away is dropped")
    func subscriberRemoved() async {
        let (store, _) = makeStore()
        do {
            var iterator = store.changes.makeAsyncIterator()
            _ = await iterator.next()
            #expect(store.subscriberCount == 1)
        }
        // Termination hops back to the main actor; give it a few turns.
        for _ in 0..<100 where store.subscriberCount > 0 { await Task.yield() }
        #expect(store.subscriberCount == 0)
        store.setLastError("nobody listening")   // must not trap or leak
    }

    @Test("a slow subscriber keeps the newest states, not the oldest")
    func slowSubscriber() async {
        let (store, _) = makeStore()
        var iterator = store.changes.makeAsyncIterator()
        for number in 0..<100 { store.setLastError("e\(number)") }

        var last: SwitchboardState?
        for _ in 0..<StateStore.subscriberBuffer {
            last = await iterator.next()
        }
        #expect(last?.lastError == "e99")
    }
}
