import Actions
import DDCKit
import Devices
import ESP32Kit
import Foundation
import os
import StateStore
import SwitchboardCore
import Testing

// MARK: - Time

let instant: Sleeper = { _ in }

/// A `Sleeper` that records what it was asked to wait for and returns at once.
final class RecordingSleeper: Sendable {
    private let recorded = OSAllocatedUnfairLock<[Duration]>(initialState: [])

    var durations: [Duration] { recorded.withLock { $0 } }

    var sleeper: Sleeper {
        { [self] duration in recorded.withLock { $0.append(duration) } }
    }
}

/// Collects values from a `@Sendable` closure (the `notify` action).
final class Recorder<Value: Sendable>: Sendable {
    private let values = OSAllocatedUnfairLock<[Value]>(initialState: [])

    var all: [Value] { values.withLock { $0 } }

    func record(_ value: Value) { values.withLock { $0.append(value) } }
}

struct TimeoutError: Error {}

/// Runs `body` with a deadline so a hang fails the test instead of stalling the suite. The timer
/// only matters when something is wrong.
func withTimeout<T: Sendable>(_ limit: Duration = .seconds(10), _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw TimeoutError() }
        return first
    }
}

/// A fresh directory that is removed afterwards. The directory itself is not created. Runs in the
/// caller's actor, so a `@MainActor` test can pass a closure that touches its main-actor state.
func withTempDirectory<T>(actor: isolated (any Actor)? = #isolation, _ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory.appending(path: "switchboard-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

// MARK: - A monitor

/// The DualUp's PBP state as the two transports see it: the video cable reads it (and accepts only
/// `0xD7 = 1`), the USB bridge cannot be read (and accepts only `0xD7 = 0`). The opposite value on
/// each transport is ignored, as on the real monitor (brief, section 3).
actor FakeMonitor {
    private(set) var pbp: UInt16
    private(set) var mainInput: UInt16
    /// "USB bridge: 0xD7 = 0", "video cable: 0xD7 = 1", ... in order.
    private(set) var writes: [String] = []
    /// When true the monitor ignores every write (the USB bridge bug of GitHub issue 5).
    var ignoresWrites = false

    init(pbp: UInt16 = 1, mainInput: UInt16 = 1) {
        self.pbp = pbp
        self.mainInput = mainInput
    }

    func setIgnoresWrites(_ value: Bool) { ignoresWrites = value }
    /// The monitor changed by itself (someone pressed a button on it).
    func setPBP(_ value: UInt16) { pbp = value }

    fileprivate func bridgeWrite(_ write: VCPWrite) {
        writes.append("USB bridge: 0x\(String(write.code, radix: 16, uppercase: true)) = \(write.value)")
        if !ignoresWrites, write.code == 0xD7, write.value == 0 { pbp = 0 }
    }

    fileprivate func cableWrite(_ write: VCPWrite) {
        writes.append("video cable: 0x\(String(write.code, radix: 16, uppercase: true)) = \(write.value)")
        if !ignoresWrites, write.code == 0xD7, write.value == 1 { pbp = 1 }
    }

    fileprivate func read(code: UInt8) -> UInt16? {
        switch code {
        case 0xD7: return pbp
        case 0xF5: return mainInput
        default: return nil
        }
    }

    nonisolated var cable: any DDCTransport { FakeMonitorCable(monitor: self) }
    nonisolated var bridge: any DDCTransport { FakeMonitorBridge(monitor: self) }

    /// An `LGDualUp` over this monitor with no real waiting.
    nonisolated func dualUp() -> LGDualUp {
        LGDualUp(videoCable: cable, usbBridge: bridge, sleep: instant)
    }
}

private struct FakeMonitorCable: DDCTransport {
    let monitor: FakeMonitor
    var name: String { "fake video cable" }

    func write(_ write: VCPWrite) async throws { await monitor.cableWrite(write) }

    func read(code: UInt8) async throws -> VCPReply {
        guard let value = await monitor.read(code: code) else { throw DDCError.noReply }
        return VCPReply(resultCode: 0, code: code, maximum: 0xFF, current: value)
    }
}

private struct FakeMonitorBridge: DDCTransport {
    let monitor: FakeMonitor
    var name: String { "fake USB bridge" }

    func write(_ write: VCPWrite) async throws { await monitor.bridgeWrite(write) }
    func read(code: UInt8) async throws -> VCPReply { throw DDCError.readUnsupported }
}

/// A `DualUp` whose video cable never leaves PBP off (`0xD7` always reads 1), built from the
/// stock `FakeDDC`: every `perform(.pbpOn)` through it ends unverified.
func stuckOffDualUp() -> (LGDualUp, cable: FakeDDC, bridge: FakeDDC) {
    let cable = FakeDDC(name: "fake video cable", reads: [0xD7: [1], 0xF5: [1]])
    let bridge = FakeDDC(name: "fake USB bridge", supportsRead: false)
    return (LGDualUp(videoCable: cable, usbBridge: bridge, sleep: instant), cable, bridge)
}

// MARK: - A controller

/// Holds callers back until `release()`.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// A `ControllerClient` that keeps its state in memory, records every call, and can be told to fail,
/// to hold calls at a gate, or to answer without doing what was asked.
actor FakeController: ControllerClient {
    private var current: ControllerState
    private(set) var calls: [String] = []
    private var failure: ControllerError?
    private var gate: Gate?
    private var ignoresRequests = false
    private let eventStream: AsyncStream<ControllerState>
    private let eventContinuation: AsyncStream<ControllerState>.Continuation

    init(state: ControllerState = FakeController.initialState) {
        self.current = state
        (eventStream, eventContinuation) = AsyncStream<ControllerState>.makeStream()
    }

    static let initialState = ControllerState(
        hdmi: [.dualup: 1, .lg4k: 1, .samsung: 1],
        usb: .init(port: 1, source: "aten"),
        uptime: 10
    )

    func fail(with error: ControllerError?) { failure = error }
    func hold(at gate: Gate?) { self.gate = gate }
    /// Answers every command with the unchanged state, as a controller that did not act would.
    func ignoreRequests(_ value: Bool) { ignoresRequests = value }
    func push(_ state: ControllerState) {
        current = state
        eventContinuation.yield(state)
    }

    func state() async throws -> ControllerState {
        calls.append("state")
        if let failure { throw failure }
        return current
    }

    func selectHDMI(_ display: DisplayID, input: Int) async throws -> ControllerState {
        try await command("selectHDMI(\(display.rawValue), \(input))") { $0.hdmi[display] = input }
    }

    func resyncHDMI(_ display: DisplayID, input: Int) async throws -> ControllerState {
        try await command("resyncHDMI(\(display.rawValue), \(input))") { $0.hdmi[display] = input }
    }

    func selectUSB(port: Int) async throws -> ControllerState {
        try await command("selectUSB(\(port))") { $0.usb.port = port }
    }

    nonisolated func events() -> AsyncStream<ControllerState> { eventStream }

    private func command(_ name: String, _ change: (inout ControllerState) -> Void) async throws -> ControllerState {
        calls.append(name)
        if let gate { await gate.wait() }
        if let failure { throw failure }
        if !ignoresRequests { change(&current) }
        return current
    }
}

// MARK: - A wired-up runner

/// The pieces of one runner test.
@MainActor
struct Rig {
    let store: StateStore
    let monitor: FakeMonitor
    let controller: FakeController
    let sleeper: RecordingSleeper
    let notified: Recorder<String>
    let macros: MacroStore
    let runner: MacroRunner
    let context: ActionContext

    /// - Parameters:
    ///   - dualUp: replaces the `LGDualUp` over `monitor`.
    ///   - withMonitor: false for a context with no monitor at all.
    ///   - withController: false for a context with no controller.
    init(
        directory: URL,
        monitor: FakeMonitor = FakeMonitor(),
        dualUp: LGDualUp? = nil,
        withMonitor: Bool = true,
        controller: FakeController = FakeController(),
        withController: Bool = true
    ) {
        let store = StateStore()
        let sleeper = RecordingSleeper()
        let notified = Recorder<String>()
        let resolvedDualUp: LGDualUp? = withMonitor ? (dualUp ?? monitor.dualUp()) : nil
        let context = ActionContext(
            dualUp: resolvedDualUp,
            controller: withController ? controller : nil,
            store: store,
            notify: { notified.record($0) },
            sleep: sleeper.sleeper
        )
        let macros = MacroStore(directory: directory)
        self.store = store
        self.monitor = monitor
        self.controller = controller
        self.sleeper = sleeper
        self.notified = notified
        self.macros = macros
        self.context = context
        self.runner = MacroRunner(registry: ActionRegistry(), macros: macros, context: context)
    }
}

/// Every event of one run, up to and including the terminal one.
func collect(_ stream: AsyncStream<RunEvent>, for handle: RunHandle) async throws -> [RunEvent] {
    try await withTimeout {
        var events: [RunEvent] = []
        for await event in stream where event.runId == handle.runId {
            events.append(event)
            if event.isTerminal { break }
        }
        return events
    }
}

/// Starts a run and returns its events.
func runAndCollect(_ runner: MacroRunner, _ id: String, _ parameters: [String: JSONValue] = [:]) async throws -> (handle: RunHandle, events: [RunEvent]) {
    let stream = await runner.events
    let handle = try await runner.start(id: id, parameters: parameters)
    return (handle, try await collect(stream, for: handle))
}

/// `status:step` pairs, which is what the event order is about.
func summary(_ events: [RunEvent]) -> [String] {
    events.map { "\($0.status.rawValue):\($0.step)/\($0.stepCount)" }
}
