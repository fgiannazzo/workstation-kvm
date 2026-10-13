import DDCKit
import Devices
import Foundation
import StateStore
import SwitchboardCore

/// Keeps the `StateStore` current while the app runs: polls the monitor over the video cable
/// every `interval`, feeds the controller's state into the store, both from its event stream
/// and from a poll (the stream says nothing when the controller goes away, a failed poll does),
/// and reads whether the displays are connected (`displays`).
///
/// Reads only; it never writes to any device. The CLI does not start it (a CLI command reads what
/// it needs when it needs it).
@MainActor
public final class StateRefresher {
    private let dualUp: LGDualUp?
    private let controller: (any ControllerClient)?
    private let displays: DisplaySwitch?
    private let store: StateStore
    private let interval: Duration
    private let sleep: Sleeper
    private let activity: (@Sendable () async -> RunActivity)?
    private var tasks: [Task<Void, Never>] = []

    /// - Parameters:
    ///   - interval: time between polls (`Settings.pollingIntervalSeconds`).
    ///   - sleep: injected so tests do not wait.
    ///   - activity: the runner's `activity`. A poll that overlaps a run is discarded: a run
    ///     reads the monitor itself, after its own settle wait, and that reading must win.
    public init(
        dualUp: LGDualUp?,
        controller: (any ControllerClient)?,
        displays: DisplaySwitch? = nil,
        store: StateStore,
        interval: Duration,
        sleep: @escaping Sleeper = Timing.realSleep,
        activity: (@Sendable () async -> RunActivity)? = nil
    ) {
        self.dualUp = dualUp
        self.controller = controller
        self.displays = displays
        self.store = store
        self.interval = interval
        self.sleep = sleep
        self.activity = activity
    }

    public var isRunning: Bool { !tasks.isEmpty }

    /// Polls now and then every `interval`, and starts consuming `controller.events()`. Calling it
    /// again while running does nothing.
    public func start() {
        guard tasks.isEmpty else { return }
        tasks.append(Task { [self] in
            while !Task.isCancelled {
                await refresh()
                await sleep(interval)
            }
        })
        if let controller {
            tasks.append(Task { [store] in
                for await state in controller.events() {
                    if Task.isCancelled { break }
                    store.apply(state)
                }
            })
        }
    }

    public func stop() {
        for task in tasks { task.cancel() }
        tasks = []
    }

    /// One poll of the monitor, the controller and the displays.
    public func refresh() async {
        let before = await activity?()
        if before?.isRunning == true { return }

        var reading: DualUpReading?
        if let dualUp { reading = await dualUp.readState() }
        var controllerState: Result<ControllerState, any Error>?
        if let controller {
            do { controllerState = .success(try await controller.state()) } catch { controllerState = .failure(error) }
        }
        var displaysState: DisplaysState?
        if let displays { displaysState = await displays.read() }

        // A run that started (or ran) while we were reading owns the monitor state now.
        if let before, await activity?() != before { return }
        if Task.isCancelled { return }

        if let displaysState, displaysState != store.state.displays {
            store.log(.info, "displays \(displaysState.rawValue)")
            store.setDisplays(displaysState)
        }
        if let reading {
            let reachable = !reading.raw.isEmpty
            if reachable != store.state.dualUpReachable {
                store.log(reachable ? .info : .warning, reachable ? "monitor reachable" : "monitor not answering on the video cable")
            }
            store.applyMonitor(pbp: reading.pbp, mainInput: reading.mainInput, reachable: reachable)
        }
        switch controllerState {
        case .success(let state)?:
            if !store.state.controllerReachable { store.log(.info, "controller reachable") }
            store.apply(state)
        case .failure(let error)?:
            if error is CancellationError { return }
            if store.state.controllerReachable { store.log(.warning, "controller not answering: \(error)") }
            store.setControllerReachable(false)
        case nil:
            break
        }
    }
}
