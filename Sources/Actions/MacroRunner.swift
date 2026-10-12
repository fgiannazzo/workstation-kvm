import DDCKit
import Foundation
import StateStore
import SwitchboardCore

/// Whether a run is in progress and how many have started. `StateRefresher` reads it before and
/// after a poll and throws the poll away if anything ran in between, so a stale reading can never
/// overwrite what a run just verified.
public struct RunActivity: Sendable, Equatable {
    public var isRunning: Bool
    public var started: Int

    public init(isRunning: Bool, started: Int) {
        self.isRunning = isRunning
        self.started = started
    }
}

/// Runs macros and single actions, one at a time, and reports progress as `RunEvent`s.
///
/// `start` answers at once with a `RunHandle` (that is `POST /run/{id}`'s `202`); the steps run in
/// a task of their own. A macro runs its steps in order and stops at the first one that fails;
/// an unverified monitor write is a failure. After the last step the macro's `verify` is checked
/// against the store. Every step and every outcome is logged to the `StateStore`.
public actor MacroRunner {
    private static let finishedRunsKept = 16

    private let registry: ActionRegistry
    private let macros: MacroStore
    private let context: ActionContext

    private var subscribers: [UUID: AsyncStream<RunEvent>.Continuation] = [:]
    private var active: RunHandle?
    private var startedCount = 0
    private var outcomes: [String: (event: RunEvent, error: ActionError?)] = [:]
    private var outcomeOrder: [String] = []
    private var waiters: [String: [CheckedContinuation<RunEvent, Never>]] = [:]

    public init(registry: ActionRegistry, macros: MacroStore, context: ActionContext) {
        self.registry = registry
        self.macros = macros
        self.context = context
    }

    // MARK: Starting

    /// Starts the macro `id`, or the action `id` with `parameters` (a macro id wins when both
    /// exist; macros ignore `parameters`). Returns as soon as the run is accepted and `started` has
    /// been published.
    ///
    /// Throws `ActionError.unknownID`, `.missingParameter` or `.invalidParameter` (nothing ran),
    /// `.busy(runID:)` while another run is in progress, or a `MacroStoreError` when `macros.json`
    /// cannot be loaded and `id` is not an action id. A run that cannot work with this
    /// context (a controller step with no controller, a monitor step with no monitor) is accepted
    /// and fails before its first step: `started`, then `failed` with `step` 0.
    public func start(id: String, parameters: [String: JSONValue] = [:]) async throws -> RunHandle {
        let kind: RunHandle.Kind
        let steps: [MacroStep]
        let verify: MacroVerify?

        if let macro = try await lookUpMacro(id) {
            kind = .macro
            steps = macro.steps
            verify = macro.verify   // MacroStore only hands out macros that passed MacroValidator
        } else if let action = ActionID(rawValue: id) {
            _ = try registry.validate(action, parameters: parameters)
            kind = .action
            steps = [MacroStep(action: action, parameters: parameters)]
            verify = nil
        } else {
            throw ActionError.unknownID(id)
        }

        // From here to the task being created there is no suspension point: the busy check and the
        // claim on the single run slot cannot be interleaved with another `start`.
        if let active { throw ActionError.busy(runID: active.runId) }
        let handle = RunHandle(runId: UUID().uuidString.lowercased(), id: id, kind: kind)
        active = handle
        startedCount += 1
        emit(RunEvent(runId: handle.runId, id: id, kind: kind, status: .started, step: 0, stepCount: steps.count, message: ""))
        Task { await self.runSteps(handle: handle, steps: steps, verify: verify) }
        return handle
    }

    private func lookUpMacro(_ id: String) async throws -> Macro? {
        do {
            return try await macros.macro(id: id)
        } catch let error as MacroStoreError {
            // A broken macros.json must not hide the plain actions, but a macro id that is
            // simply absent from a readable file is not an error here either.
            if ActionID(rawValue: id) != nil { return nil }
            throw error
        }
    }

    // MARK: Events

    /// Every run event from now on. Each access is an independent stream (any number of
    /// subscribers); it ends when the consumer stops iterating. A subscriber sees runs that start
    /// after it subscribed, so subscribe before `start`.
    public var events: AsyncStream<RunEvent> {
        let (stream, continuation) = AsyncStream<RunEvent>.makeStream()
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    /// How many `events` streams are open. A test hook.
    public var subscriberCount: Int { subscribers.count }

    /// The run that is in progress, if any.
    public var currentRun: RunHandle? { active }

    public var activity: RunActivity {
        RunActivity(isRunning: active != nil, started: startedCount)
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func emit(_ event: RunEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    // MARK: Waiting

    /// The `finished` or `failed` event of a run, waiting for it if it is still going. A run this
    /// runner never started (or one old enough to have been forgotten) answers with a `failed`
    /// event saying so.
    public func wait(_ handle: RunHandle) async -> RunEvent {
        if let outcome = outcomes[handle.runId] { return outcome.event }
        guard active?.runId == handle.runId else {
            return RunEvent(
                runId: handle.runId, id: handle.id, kind: handle.kind, status: .failed,
                step: 0, stepCount: 0, message: "no such run"
            )
        }
        return await withCheckedContinuation { continuation in
            waiters[handle.runId, default: []].append(continuation)
        }
    }

    /// Why a run failed, once it has; nil for a run that finished, is still going or is forgotten.
    /// The runner keeps the last 16 runs.
    public func error(of handle: RunHandle) -> ActionError? {
        outcomes[handle.runId]?.error
    }

    /// Starts a run and reports every one of its events to `onEvent` until it ends. This is what
    /// `switchboardctl run` does; it is also the simplest way to run something and know how it ended.
    public func execute(
        id: String,
        parameters: [String: JSONValue] = [:],
        onEvent: @Sendable (RunEvent) -> Void
    ) async throws -> RunReport {
        let stream = events
        let handle = try await start(id: id, parameters: parameters)
        var terminal: RunEvent?
        for await event in stream where event.runId == handle.runId {
            onEvent(event)
            if event.isTerminal {
                terminal = event
                break
            }
        }
        let final: RunEvent
        if let terminal {
            final = terminal
        } else {
            final = await wait(handle)
        }
        return RunReport(handle: handle, terminal: final, error: error(of: handle))
    }

    // MARK: Running

    private func runSteps(handle: RunHandle, steps: [MacroStep], verify: MacroVerify?) async {
        let stepCount = steps.count
        let store = context.store

        // A macro that needs a device this process does not have fails before it moves anything:
        // `guest` must not turn PBP on and then discover there is no controller for `usb.select`.
        for step in steps {
            do {
                try registry.checkAvailability(of: step.action, in: context)
            } catch let error as ActionError {
                await finish(handle, stepCount: stepCount, status: .failed, step: 0, message: "\(step.action.rawValue): \(error)", error: error)
                return
            } catch {
                continue
            }
        }

        await store.log(.info, "run \(handle.id) started (\(stepCount) step\(stepCount == 1 ? "" : "s"))")

        for (index, step) in steps.enumerated() {
            let number = index + 1
            if Task.isCancelled {
                await finish(handle, stepCount: stepCount, status: .failed, step: number, message: "\(ActionError.cancelled)", error: .cancelled)
                return
            }
            do {
                let message = try await registry.run(step.action, parameters: step.parameters, context: context)
                await store.log(.info, "run \(handle.id) step \(number)/\(stepCount): \(message)")
                emit(RunEvent(runId: handle.runId, id: handle.id, kind: handle.kind, status: .step, step: number, stepCount: stepCount, message: message))
            } catch {
                let failure = (error as? ActionError) ?? (error is CancellationError ? .cancelled : .monitorUnavailable("\(error)"))
                await finish(handle, stepCount: stepCount, status: .failed, step: number, message: "\(step.action.rawValue): \(failure)", error: failure)
                return
            }
        }

        if let verify {
            let mismatches = verify.mismatches(in: await store.state)
            if !mismatches.isEmpty {
                let failure = ActionError.verifyFailed(mismatches)
                await finish(handle, stepCount: stepCount, status: .failed, step: stepCount, message: "\(failure)", error: failure)
                return
            }
        }
        await finish(handle, stepCount: stepCount, status: .finished, step: stepCount, message: "ok", error: nil)
    }

    /// Records the outcome (log, last error), releases the run slot and publishes the terminal
    /// event. The slot is released in the same turn as the event, so a client that sees `finished`
    /// can start the next run at once.
    private func finish(
        _ handle: RunHandle,
        stepCount: Int,
        status: RunEvent.Status,
        step: Int,
        message: String,
        error: ActionError?
    ) async {
        let store = context.store
        if status == .failed {
            await store.log(.error, "run \(handle.id) failed: \(message)")
            // A macro's message names the failing action; say which macro it was.
            await store.setLastError(handle.kind == .macro ? "\(handle.id): \(message)" : message)
        } else {
            await store.log(.info, "run \(handle.id) finished")
            await store.setLastError(nil)
        }

        let event = RunEvent(runId: handle.runId, id: handle.id, kind: handle.kind, status: status, step: step, stepCount: stepCount, message: message)
        active = nil
        outcomes[handle.runId] = (event, error)
        outcomeOrder.append(handle.runId)
        if outcomeOrder.count > Self.finishedRunsKept {
            outcomes[outcomeOrder.removeFirst()] = nil
        }
        emit(event)
        for waiter in waiters.removeValue(forKey: handle.runId) ?? [] {
            waiter.resume(returning: event)
        }
    }
}
