import Foundation

/// What `POST /run/{id}` answers with (`202 Accepted`): `{ "runId": "7f3c…", "id": "guest", "kind": "macro" }`.
public struct RunHandle: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case macro
        case action
    }

    public var runId: String
    /// The macro id or action id that was started.
    public var id: String
    public var kind: Kind

    public init(runId: String, id: String, kind: Kind) {
        self.runId = runId
        self.id = id
        self.kind = kind
    }
}

/// One `run` event of `GET /events` (`docs/API.md`):
/// `{"runId":"…","id":"guest","kind":"macro","status":"step","step":1,"stepCount":2,"message":"…"}`.
///
/// - `started`: `step` is 0, `message` is empty.
/// - `step`: `step` steps are done (1 after the first); `message` is what that step reported.
/// - `finished`: `step == stepCount`, `message` is `ok`.
/// - `failed`: `step` is the 1-based number of the step that failed (the verify after the last
///   step counts as `stepCount`), or 0 when the run failed before its first step; `message` is the
///   error.
public struct RunEvent: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case started
        case step
        case finished
        case failed
    }

    public var runId: String
    public var id: String
    public var kind: RunHandle.Kind
    public var status: Status
    public var step: Int
    public var stepCount: Int
    public var message: String

    public init(runId: String, id: String, kind: RunHandle.Kind, status: Status, step: Int, stepCount: Int, message: String) {
        self.runId = runId
        self.id = id
        self.kind = kind
        self.status = status
        self.step = step
        self.stepCount = stepCount
        self.message = message
    }

    /// `finished` or `failed`: nothing follows for this run.
    public var isTerminal: Bool {
        status == .finished || status == .failed
    }

    /// One line of text, as `switchboardctl run` prints it:
    ///
    ///     started guest (2 steps)
    ///     step 1/2: monitor.pbp.on: verified 0xD7 = 0
    ///     finished guest: ok
    ///     failed guest at step 1/2: monitor.pbp.on: unverified: 0xD7 read back 1 (off), expected 0 (on)
    public var line: String {
        switch status {
        case .started:
            return "started \(id) (\(stepCount) step\(stepCount == 1 ? "" : "s"))"
        case .step:
            return "step \(step)/\(stepCount): \(message)"
        case .finished:
            return "finished \(id): \(message)"
        case .failed:
            let where_ = step == 0 ? "before step 1" : "at step \(step)/\(stepCount)"
            return "failed \(id) \(where_): \(message)"
        }
    }
}

/// How a run ended, for callers that stream it to a terminal (`MacroRunner.execute`).
public struct RunReport: Sendable, Equatable {
    public let handle: RunHandle
    /// The `finished` or `failed` event.
    public let terminal: RunEvent
    /// Why it failed; nil when it finished.
    public let error: ActionError?

    public var succeeded: Bool { terminal.status == .finished }
}
