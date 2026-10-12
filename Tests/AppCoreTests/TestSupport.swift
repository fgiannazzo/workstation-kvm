import Actions
import AppCore
import DDCKit
import Devices
import ESP32Kit
import Foundation
import os
import StateStore
import SwitchboardCore
import Testing

// MARK: - Time and files

let instant: Sleeper = { _ in }

/// A fresh directory that is removed afterwards. The directory itself is not created, so a test can
/// check that nothing was written. Runs in the caller's actor.
func withTempDirectory<T>(actor: isolated (any Actor)? = #isolation, _ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "switchboard-app-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

/// Polls until `condition` holds, failing the test after `limit`. For the few things that happen on
/// a task of their own (the refresher's first poll, a run held at a gate).
@MainActor
func waitUntil(
    _ description: String,
    limit: Duration = .seconds(10),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () -> Bool
) async {
    let deadline = ContinuousClock.now + limit
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("timed out waiting for \(description)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// Collects values from a `@Sendable` closure.
final class Recorder<Value: Sendable>: Sendable {
    private let values = OSAllocatedUnfairLock<[Value]>(initialState: [])

    var all: [Value] { values.withLock { $0 } }

    func record(_ value: Value) { values.withLock { $0.append(value) } }
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

/// A `ControllerClient` that keeps its state in memory, records every call, and can be told to fail
/// or to hold commands at a gate.
actor FakeController: ControllerClient {
    private var current: ControllerState
    private(set) var calls: [String] = []
    private var failure: ControllerError?
    private var gate: Gate?
    private let eventStream: AsyncStream<ControllerState>

    init(state: ControllerState = FakeController.initialState) {
        self.current = state
        (eventStream, _) = AsyncStream<ControllerState>.makeStream()
    }

    static let initialState = ControllerState(
        hdmi: [.dualup: 1, .lg4k: 1, .samsung: 1],
        usb: .init(port: 1, source: "aten"),
        uptime: 10
    )

    func fail(with error: ControllerError?) { failure = error }
    func hold(at gate: Gate?) { self.gate = gate }

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
        change(&current)
        return current
    }
}

// MARK: - The system's services

/// A notifier that records what it was asked to show.
final class FakeNotifier: UserNotifier {
    private let posted = OSAllocatedUnfairLock<[String]>(initialState: [])
    private let outcome = OSAllocatedUnfairLock<NotificationOutcome>(initialState: .posted)

    var bodies: [String] { posted.withLock { $0 } }

    func answer(with outcome: NotificationOutcome) { self.outcome.withLock { $0 = outcome } }

    func post(title: String, body: String) async -> NotificationOutcome {
        posted.withLock { $0.append(body) }
        return outcome.withLock { $0 }
    }
}

/// A login item that lives in memory.
final class FakeLoginItem: LaunchAtLoginService {
    struct Failure: Error, CustomStringConvertible, LocalizedError {
        var description: String
        var errorDescription: String? { description }
    }

    private struct State {
        var status: LaunchAtLoginStatus
        var registerStatus: LaunchAtLoginStatus = .enabled
        var failure: Failure?
        var calls: [String] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(status: LaunchAtLoginStatus = .notRegistered) {
        state = OSAllocatedUnfairLock(initialState: State(status: status))
    }

    var status: LaunchAtLoginStatus { state.withLock { $0.status } }
    var calls: [String] { state.withLock { $0.calls } }

    /// What `status` becomes after `register()` (`.requiresApproval` before the user approves).
    func registering(becomes status: LaunchAtLoginStatus) { state.withLock { $0.registerStatus = status } }
    func fail(with message: String?) { state.withLock { $0.failure = message.map(Failure.init(description:)) } }

    func register() throws {
        try state.withLock { state in
            state.calls.append("register")
            if let failure = state.failure { throw failure }
            state.status = state.registerStatus
        }
    }

    func unregister() throws {
        try state.withLock { state in
            state.calls.append("unregister")
            if let failure = state.failure { throw failure }
            state.status = .notRegistered
        }
    }

    func openSystemSettings() { state.withLock { $0.calls.append("openSystemSettings") } }
}

// MARK: - An AppModel over fakes

/// An `AppModel` whose `Runtime` is built over a `FakeController` and a `FakeDDC` monitor, with
/// notifications, the login item and mDNS faked too. Nothing here touches hardware, the network or
/// the system.
@MainActor
struct ModelRig {
    let model: AppModel
    let directory: URL
    let controller: FakeController
    let cable: FakeDDC
    let bridge: FakeDDC
    let notifier: FakeNotifier
    let loginItem: FakeLoginItem
    /// The settings each `Runtime` was built from, in order.
    let builtWith: Recorder<Settings>
    let discovered: Recorder<Duration>

    /// - Parameters:
    ///   - pbp: what the video cable reads for 0xD7 (0 = on, 1 = off); 1 until a test changes it.
    ///   - found: what the fake mDNS lookup finds.
    init(
        directory: URL,
        pbp: UInt16 = 1,
        loginStatus: LaunchAtLoginStatus = .notRegistered,
        found: DiscoveredController? = nil,
        environment: [String: String] = [:]
    ) {
        let controller = FakeController()
        let cable = FakeDDC(name: "fake video cable", reads: [0xD7: [pbp], 0xF5: [1]])
        let bridge = FakeDDC(name: "fake USB bridge", supportsRead: false)
        let notifier = FakeNotifier()
        let loginItem = FakeLoginItem(status: loginStatus)
        let builtWith = Recorder<Settings>()
        let discovered = Recorder<Duration>()

        self.directory = directory
        self.controller = controller
        self.cable = cable
        self.bridge = bridge
        self.notifier = notifier
        self.loginItem = loginItem
        self.builtWith = builtWith
        self.discovered = discovered
        self.model = AppModel(
            environment: environment,
            supportDirectory: directory,
            runtimeFactory: { settings, store, notify in
                builtWith.record(settings)
                return Runtime(
                    settings: settings,
                    controllerURL: settings.controllerURL ?? URL(string: "http://fake:1"),
                    dualUp: LGDualUp(videoCable: cable, usbBridge: bridge, sleep: instant),
                    controller: controller,
                    appSupport: directory,
                    notify: notify,
                    store: store
                )
            },
            notifier: notifier,
            loginItem: loginItem,
            discovery: { timeout in
                discovered.record(timeout)
                return found
            }
        )
    }
}

/// Every log message, oldest first.
@MainActor
func logMessages(_ model: AppModel) -> [String] {
    model.log.map(\.message)
}
