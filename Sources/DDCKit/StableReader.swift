/// Settle-and-double-dump reads (prototype `dualup.py`, `dump`).
///
/// The DualUp answers manufacturer codes unreliably, especially while the link re-trains after
/// a mode change. So: read every code, wait `Timing.betweenDumps`, read them again and keep only
/// the codes whose two values agree. If any requested code is missing, wait `retryGap` and try
/// again, up to `maxAttempts`; the largest agreeing set wins. A code that never reads is absent
/// from the result. Absent means unknown, never "changed", and never a default.
public struct StableReader: Sendable {
    public var maxAttempts: Int
    public var retryGap: Duration
    private let sleep: Sleeper

    public init(sleep: @escaping Sleeper = Timing.realSleep, maxAttempts: Int = 4, retryGap: Duration = .seconds(2)) {
        self.sleep = sleep
        self.maxAttempts = max(1, maxAttempts)
        self.retryGap = retryGap
    }

    public func read(codes: [UInt8], from transport: any DDCTransport) async -> [UInt8: UInt16] {
        var best: [UInt8: UInt16] = [:]
        for attempt in 0..<maxAttempts {
            let first = await dumpOnce(codes, from: transport)
            await sleep(Timing.betweenDumps)
            let second = await dumpOnce(codes, from: transport)

            let stable = first.filter { second[$0.key] == $0.value }
            if stable.count > best.count { best = stable }
            if stable.count == codes.count { break }
            if attempt < maxAttempts - 1 { await sleep(retryGap) }
        }
        return best
    }

    /// One pass: the current value of every code the display answered with result code 0.
    func dumpOnce(_ codes: [UInt8], from transport: any DDCTransport) async -> [UInt8: UInt16] {
        var values: [UInt8: UInt16] = [:]
        for code in codes {
            guard let reply = try? await transport.read(code: code), reply.isOK else { continue }
            values[code] = reply.current
        }
        return values
    }
}
