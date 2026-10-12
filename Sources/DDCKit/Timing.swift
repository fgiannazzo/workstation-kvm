/// An injectable sleep. Production code passes `Timing.realSleep`; tests pass a closure that
/// records the requested duration and returns at once, so the suite never waits.
public typealias Sleeper = @Sendable (Duration) async -> Void

/// Every delay in the DDC path, in one place (brief, section 3; prototype `dualup.py`).
public enum Timing {
    /// After any mode change the link re-trains; wait this long before reading.
    public static let settleAfterModeChange: Duration = .seconds(4)
    /// Gap between the two passes of a settle-and-double-dump read.
    public static let betweenDumps: Duration = .milliseconds(500)
    /// Gap between retries of a single VCP get.
    public static let readRetryGap: Duration = .milliseconds(150)
    /// Gap between sending a get request and reading its 12-byte reply.
    public static let requestToReply: Duration = .milliseconds(50)

    /// `Task.sleep`, wrapped so cancellation is swallowed (the caller checks `Task.isCancelled`
    /// if it cares) and the signature matches `Sleeper`.
    public static let realSleep: Sleeper = { duration in
        try? await Task.sleep(for: duration)
    }
}
