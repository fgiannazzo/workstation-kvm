import Actions
import Foundation

/// What the popover's run row shows, reduced from the `RunEvent`s of one run at a time.
///
///     started   -> isRunning, currentStep 0 of stepCount, outcome none
///     step      -> currentStep = steps done, lastMessage = what that step reported
///     finished  -> not running, outcome finished, lastMessage "ok"
///     failed    -> not running, outcome failed, lastMessage = the error
///
/// An event of a run other than the one in progress is ignored, so a late event cannot rewrite
/// the row. A `started` event always begins a new run.
public struct RunProgress: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case none
        case finished
        case failed
    }

    /// The macro or action id of the latest run; nil before any run.
    public private(set) var id: String?
    public private(set) var runID: String?
    public private(set) var isRunning = false
    /// Steps done so far; on `failed`, the 1-based step that failed (0: before the first step).
    public private(set) var currentStep = 0
    public private(set) var stepCount = 0
    public private(set) var lastMessage = ""
    public private(set) var lastOutcome: Outcome = .none

    public init() {}

    public mutating func apply(_ event: RunEvent) {
        switch event.status {
        case .started:
            id = event.id
            runID = event.runId
            isRunning = true
            currentStep = 0
            stepCount = event.stepCount
            lastMessage = ""
            lastOutcome = .none
        case .step:
            guard isRunning, event.runId == runID else { return }
            currentStep = event.step
            stepCount = event.stepCount
            lastMessage = event.message
        case .finished:
            guard event.runId == runID else { return }
            isRunning = false
            currentStep = event.step
            stepCount = event.stepCount
            lastMessage = event.message
            lastOutcome = .finished
        case .failed:
            guard event.runId == runID else { return }
            isRunning = false
            currentStep = event.step
            stepCount = event.stepCount
            lastMessage = event.message
            lastOutcome = .failed
        }
    }

    /// A run that never started: an unknown id, a missing parameter. There is no event for it, so the
    /// row is told directly.
    public mutating func reject(id: String, message: String) {
        self.id = id
        runID = nil
        isRunning = false
        currentStep = 0
        stepCount = 0
        lastMessage = message
        lastOutcome = .failed
    }

    /// 0 to 1, for a progress bar.
    public var fraction: Double {
        guard stepCount > 0 else { return 0 }
        return min(1, max(0, Double(currentStep) / Double(stepCount)))
    }

    /// One line for the run row: `Running guest, step 1 of 2`, `Finished guest`,
    /// `Failed guest: monitor.pbp.on: unverified: ...`; empty before any run.
    public var statusLine: String {
        guard let id else { return "" }
        if isRunning {
            if stepCount == 0 { return "Running \(id)" }
            return "Running \(id), step \(min(currentStep + 1, stepCount)) of \(stepCount)"
        }
        switch lastOutcome {
        case .none: return ""
        case .finished: return "Finished \(id)"
        case .failed: return lastMessage.isEmpty ? "Failed \(id)" : "Failed \(id): \(lastMessage)"
        }
    }
}
