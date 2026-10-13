import Actions
import DDCKit
import Devices
import ESP32Kit
import Foundation
import os
import StateStore
import SwitchboardCore
import Testing

@MainActor
@Suite("Runtime")
struct RuntimeTests {
    @Test("live builds the real transports for the configured display and no controller when none is set")
    func liveWithoutController() async throws {
        try await withTempDirectory { directory in
            // Constructing touches no hardware: devices are used when an action runs.
            let runtime = Runtime.live(settings: Settings(displayNameContains: "DualUp"), environment: [:], appSupport: directory)

            #expect(runtime.controller == nil)
            #expect(runtime.controllerURL == nil)
            #expect(runtime.context.controller == nil)
            #expect(runtime.dualUp.videoCable.name == "video cable (DualUp)")
            #expect(runtime.dualUp.usbBridge.name == "USB bridge (DualUp)")
            #expect(runtime.context.dualUp != nil)
            #expect(runtime.macros.directory == directory)
            #expect(!runtime.refresher.isRunning, "live does not start polling")
            #expect(runtime.registry.descriptors.count == 10)
            #expect(runtime.store.state == SwitchboardState())
            #expect(!FileManager.default.fileExists(atPath: directory.path), "nothing is written until a store is used")
        }
    }

    @Test("live builds around the store it is given, so a rebuilt runtime keeps the log and the last reading")
    func liveKeepsGivenStore() async throws {
        try await withTempDirectory { directory in
            let store = StateStore()
            store.log(.info, "before")
            store.applyMonitor(pbp: .on, mainInput: .hdmi2, reachable: true)

            let runtime = Runtime.live(settings: Settings(), environment: [:], appSupport: directory, store: store)

            #expect(runtime.store === store)
            #expect(runtime.context.store === store)
            #expect(runtime.store.log.map(\.message) == ["before"])
            #expect(runtime.store.state.pbp == .on)
        }
    }

    @Test("live builds an ESP32Client for the configured controller URL")
    func liveWithController() async throws {
        try await withTempDirectory { directory in
            let settings = Settings(controllerURL: URL(string: "http://192.168.1.50:80"))
            let runtime = Runtime.live(settings: settings, environment: [:], appSupport: directory)

            let client = try #require(runtime.controller as? ESP32Client)
            #expect(client.baseURL.absoluteString == "http://192.168.1.50:80")
            #expect(runtime.controllerURL?.absoluteString == "http://192.168.1.50:80")
            #expect(runtime.context.controller != nil)
        }
    }

    @Test("SWITCHBOARD_CONTROLLER_URL in the environment overrides the saved address")
    func liveEnvironmentOverride() async throws {
        try await withTempDirectory { directory in
            let settings = Settings(controllerURL: URL(string: "http://saved:80"))
            let runtime = Runtime.live(
                settings: settings,
                environment: ["SWITCHBOARD_CONTROLLER_URL": "http://127.0.0.1:48700"],
                appSupport: directory
            )
            #expect((runtime.controller as? ESP32Client)?.baseURL.absoluteString == "http://127.0.0.1:48700")

            let onlyEnvironment = Runtime.live(
                settings: Settings(),
                environment: ["SWITCHBOARD_CONTROLLER_URL": "http://127.0.0.1:48700"],
                appSupport: directory
            )
            #expect(onlyEnvironment.controller != nil)
        }
    }

    @Test("the wiring runs a default macro end to end: guest, then solo, over fakes")
    func wiredRuntimeRunsMacros() async throws {
        try await withTempDirectory { directory in
            let monitor = FakeMonitor()
            let controller = FakeController()
            let sleeper = RecordingSleeper()
            let notified = Recorder<String>()
            let runtime = Runtime(
                settings: Settings(),
                controllerURL: URL(string: "http://fake:1"),
                dualUp: monitor.dualUp(),
                controller: controller,
                appSupport: directory,
                notify: { notified.record($0) },
                sleep: sleeper.sleeper
            )

            let guest = try await runtime.runner.execute(id: "guest") { _ in }
            #expect(guest.succeeded)
            #expect(runtime.store.state.pbp == .on)
            #expect(runtime.store.state.usbPort == 2)
            #expect(FileManager.default.fileExists(atPath: directory.appending(path: "macros.json").path), "the default macros were created in appSupport")

            let solo = try await runtime.runner.execute(id: "solo") { _ in }
            #expect(solo.succeeded)
            #expect(runtime.store.state.pbp == .off)
            #expect(runtime.store.state.usbPort == 1)

            _ = try await runtime.runner.execute(id: "notify", parameters: ["text": "hi"]) { _ in }
            #expect(notified.all == ["hi"])
        }
    }
}

@MainActor
@Suite("ESP32Client end to end")
struct ControllerEndToEndTests {
    private func withMock<T>(_ body: (MockESP32, ESP32Client) async throws -> T) async throws -> T {
        let mock = MockESP32()
        try await mock.start()
        let url = try #require(await mock.url)
        do {
            let result = try await body(mock, ESP32Client(baseURL: url))
            await mock.stop()
            return result
        } catch {
            await mock.stop()
            throw error
        }
    }

    @Test("usb.select through the real ESP32Client moves the mock's USB port and lands in the store")
    func usbSelect() async throws {
        try await withTempDirectory { directory in
            try await withMock { mock, client in
                let store = StateStore()
                let context = ActionContext(dualUp: nil, controller: client, store: store, sleep: instant)
                let runner = MacroRunner(registry: ActionRegistry(), macros: MacroStore(directory: directory), context: context)

                let (handle, events) = try await runAndCollect(runner, "usb.select", ["port": 2])

                #expect(handle.kind == .action)
                #expect(summary(events) == ["started:0/1", "step:1/1", "finished:1/1"])
                #expect(events[1].message == "usb.select: port 2")
                #expect(await mock.currentState.usb.port == 2)
                #expect(store.state.usbPort == 2)
                #expect(store.state.controllerReachable)
                #expect(store.state.hdmiInput == [.dualup: 1, .lg4k: 1, .samsung: 1])
                #expect(await mock.requestLog.map { "\($0.method) \($0.path) \($0.body)" } == [#"POST /usb/select {"port":2}"#])
            }
        }
    }

    @Test("hdmi.select and hdmi.resync go over the wire as the contract says")
    func hdmi() async throws {
        try await withTempDirectory { directory in
            try await withMock { mock, client in
                let store = StateStore()
                let context = ActionContext(dualUp: nil, controller: client, store: store, sleep: instant)
                let runner = MacroRunner(registry: ActionRegistry(), macros: MacroStore(directory: directory), context: context)

                _ = try await runAndCollect(runner, "hdmi.select", ["display": "lg4k", "input": 2])
                _ = try await runAndCollect(runner, "hdmi.resync", ["display": "samsung", "input": 2])

                #expect(store.state.hdmiInput == [.dualup: 1, .lg4k: 2, .samsung: 2])
                #expect(await mock.requestLog.map { "\($0.method) \($0.path) \($0.body)" } == [
                    #"POST /hdmi/lg4k/select {"input":2}"#, #"POST /hdmi/samsung/resync {"input":2}"#,
                ])
            }
        }
    }

    @Test("guest over a fake monitor and the real client: PBP on, mock USB on port 2, verify passes")
    func guest() async throws {
        try await withTempDirectory { directory in
            try await withMock { mock, client in
                let monitor = FakeMonitor()
                let store = StateStore()
                let context = ActionContext(dualUp: monitor.dualUp(), controller: client, store: store, sleep: instant)
                let runner = MacroRunner(registry: ActionRegistry(), macros: MacroStore(directory: directory), context: context)

                let (_, events) = try await runAndCollect(runner, "guest")

                #expect(summary(events) == ["started:0/2", "step:1/2", "step:2/2", "finished:2/2"])
                #expect(await mock.currentState.usb.port == 2)
                #expect(store.state.pbp == .on)
                #expect(store.state.usbPort == 2)
            }
        }
    }

    @Test("a controller that is not there fails the run as unreachable")
    func unreachable() async throws {
        try await withTempDirectory { directory in
            let mock = MockESP32()
            try await mock.start()
            let url = try #require(await mock.url)
            await mock.stop()   // nothing listens on that port any more

            let store = StateStore()
            let client = ESP32Client(baseURL: url, timeout: .seconds(2))
            let context = ActionContext(dualUp: nil, controller: client, store: store, sleep: instant)
            let runner = MacroRunner(registry: ActionRegistry(), macros: MacroStore(directory: directory), context: context)

            let report = try await runner.execute(id: "usb.select", parameters: ["port": 2]) { _ in }
            #expect(!report.succeeded)
            #expect(report.error?.isControllerUnreachable == true)
            #expect(report.terminal.message.hasPrefix("usb.select: controller unreachable at"))
            #expect(!store.state.controllerReachable)
        }
    }
}

/// Counts how many times the refresher went to sleep, and lets a test wait for the nth.
private actor SleepCounter {
    private var count = 0
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func increment() {
        count += 1
        let ready = waiters.filter { $0.target <= count }
        waiters.removeAll { $0.target <= count }
        for waiter in ready { waiter.continuation.resume() }
    }

    func wait(for target: Int) async {
        if count >= target { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }
}

/// Lets a test decide exactly when the refresher's sleep returns.
private final class Ticker: Sendable {
    private let ticks: AsyncStream<Void>
    private let tickContinuation: AsyncStream<Void>.Continuation
    private let counter = SleepCounter()

    init() {
        (ticks, tickContinuation) = AsyncStream<Void>.makeStream()
    }

    /// Returns when `tick()` is called (or the task is cancelled).
    var sleeper: Sleeper {
        { [self] _ in
            await counter.increment()
            var iterator = ticks.makeAsyncIterator()
            _ = await iterator.next()
        }
    }

    func tick() { tickContinuation.yield() }

    /// Returns once the refresher has gone to sleep `count` times in total.
    func waitForSleeps(_ count: Int) async { await counter.wait(for: count) }
}

@MainActor
@Suite("StateRefresher")
struct StateRefresherTests {
    private func refresher(
        monitor: FakeMonitor? = FakeMonitor(),
        dualUp: LGDualUp? = nil,
        controller: FakeController? = FakeController(),
        store: StateStore = StateStore(),
        sleep: @escaping Sleeper = instant,
        activity: (@Sendable () async -> RunActivity)? = nil
    ) -> StateRefresher {
        StateRefresher(
            dualUp: dualUp ?? monitor?.dualUp(),
            controller: controller,
            store: store,
            interval: .seconds(30),
            sleep: sleep,
            activity: activity
        )
    }

    @Test("one refresh reads the monitor and the controller into the store, and never writes")
    func refreshOnce() async {
        let monitor = FakeMonitor(pbp: 0, mainInput: 2)
        let controller = FakeController(state: ControllerState(hdmi: [.dualup: 2, .lg4k: 1, .samsung: 1], usb: .init(port: 3, source: "aten"), uptime: 5))
        let store = StateStore()
        await refresher(monitor: monitor, controller: controller, store: store).refresh()

        #expect(store.state.pbp == .on)
        #expect(store.state.mainInput == .hdmi2)
        #expect(store.state.dualUpReachable)
        #expect(store.state.usbPort == 3)
        #expect(store.state.hdmiInput[.dualup] == 2)
        #expect(store.state.controllerReachable)
        #expect(await monitor.writes.isEmpty)
        #expect(await controller.calls == ["state"])
    }

    @Test("an unreadable monitor is unknown and unreachable, not a stale value")
    func monitorUnreadable() async {
        let store = StateStore()
        store.applyMonitor(pbp: .on, mainInput: .hdmi1, reachable: true)
        await refresher(dualUp: LGDualUp(videoCable: FakeDDC(), sleep: instant), controller: nil, store: store).refresh()

        #expect(store.state.pbp == .unknown)
        #expect(store.state.mainInput == .unknown)
        #expect(!store.state.dualUpReachable)
        #expect(store.log.last?.level == .warning, "going unreachable is logged once")
    }

    @Test("a controller that stops answering is marked unreachable, and coming back is logged")
    func controllerComesAndGoes() async {
        let controller = FakeController()
        let store = StateStore()
        let subject = refresher(monitor: nil, controller: controller, store: store)

        await subject.refresh()
        #expect(store.state.controllerReachable)

        await controller.fail(with: .timeout)
        await subject.refresh()
        #expect(!store.state.controllerReachable)
        await subject.refresh()   // still down: no second log line
        #expect(store.log.filter { $0.level == .warning }.count == 1)

        await controller.fail(with: nil)
        await subject.refresh()
        #expect(store.state.controllerReachable)
        #expect(store.log.map(\.message).contains("controller reachable"))
    }

    @Test("a refresh does nothing while a run is in progress")
    func skippedDuringRun() async {
        let store = StateStore()
        let monitor = FakeMonitor()
        await refresher(monitor: monitor, controller: nil, store: store, activity: { RunActivity(isRunning: true, started: 1) }).refresh()
        #expect(store.state.updatedAt == .distantPast)
    }

    @Test("a poll that overlaps a run is thrown away")
    func discardedWhenARunStartedMeanwhile() async {
        let store = StateStore()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        // The first look (before reading) sees no run, the second (after) sees one has started.
        let activity: @Sendable () async -> RunActivity = {
            let call = calls.withLock { value -> Int in value += 1; return value }
            return RunActivity(isRunning: false, started: call == 1 ? 0 : 1)
        }
        await refresher(controller: nil, store: store, activity: activity).refresh()
        #expect(store.state.updatedAt == .distantPast)
    }

    @Test("a poll with no run in between is applied")
    func appliedWhenNothingRan() async {
        let store = StateStore()
        let activity: @Sendable () async -> RunActivity = { RunActivity(isRunning: false, started: 4) }
        await refresher(controller: nil, store: store, activity: activity).refresh()
        #expect(store.state.pbp == .off)
    }

    @Test("start polls now and again after each sleep until stop; stop ends it")
    func pollingLoop() async throws {
        let monitor = FakeMonitor(pbp: 1)
        let store = StateStore()
        let ticker = Ticker()
        let subject = refresher(monitor: monitor, controller: nil, store: store, sleep: ticker.sleeper)

        subject.start()
        subject.start()   // a second start changes nothing
        #expect(subject.isRunning)

        // First poll done, now sleeping.
        try await withTimeout { await ticker.waitForSleeps(1) }
        #expect(store.state.pbp == .off)

        // The monitor changes; the next tick polls again.
        await monitor.setPBP(0)
        ticker.tick()
        try await withTimeout { await ticker.waitForSleeps(2) }
        #expect(store.state.pbp == .on)

        subject.stop()
        #expect(!subject.isRunning)
        await monitor.setPBP(1)
        ticker.tick()
        for _ in 0..<50 { await Task.yield() }
        #expect(store.state.pbp == .on, "no poll after stop")
    }

    @Test("controller events reach the store while the refresher runs")
    func controllerEvents() async throws {
        let controller = FakeController()
        let store = StateStore()
        let ticker = Ticker()
        let subject = refresher(monitor: nil, controller: controller, store: store, sleep: ticker.sleeper)
        subject.start()
        defer { subject.stop() }
        try await withTimeout { await ticker.waitForSleeps(1) }

        let pushed = ControllerState(hdmi: [.dualup: 1, .lg4k: 2, .samsung: 1], usb: .init(port: 4, source: "aten"), uptime: 99)
        await controller.push(pushed)

        try await withTimeout {
            var changes = await store.changes.makeAsyncIterator()
            while let state = await changes.next() {
                if state.usbPort == 4 { return }
            }
        }
        #expect(store.state.hdmiInput[.lg4k] == 2)
    }
}
