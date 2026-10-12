import DDCKit
import Testing

/// Records every requested sleep and returns immediately.
actor SleepLog {
    private(set) var durations: [Duration] = []
    func record(_ duration: Duration) { durations.append(duration) }
    var total: Duration { durations.reduce(.zero, +) }
}

func instantSleeper(_ log: SleepLog) -> Sleeper {
    { duration in await log.record(duration) }
}

@Suite("StableReader")
struct StableReaderTests {
    @Test("keeps codes whose two passes agree")
    func keepsAgreeing() async {
        let fake = FakeDDC(reads: [0xD7: [1], 0xF5: [1]])
        let log = SleepLog()
        let reader = StableReader(sleep: instantSleeper(log))

        let values = await reader.read(codes: [0xD7, 0xF5], from: fake)

        #expect(values == [0xD7: 1, 0xF5: 1])
        #expect(await fake.readCount(code: 0xD7) == 2)
        #expect(await fake.readCount(code: 0xF5) == 2)
        #expect(await log.durations == [Timing.betweenDumps])
    }

    @Test("drops a code whose passes disagree")
    func dropsDisagreeing() async {
        // 0xF5 alternates forever: never agrees across a pair of passes.
        let fake = FakeDDC(reads: [0xD7: [1], 0xF5: [1, 2, 1, 2, 1, 2, 1, 2, 1]])
        let log = SleepLog()
        let reader = StableReader(sleep: instantSleeper(log))

        let values = await reader.read(codes: [0xD7, 0xF5], from: fake)

        #expect(values == [0xD7: 1])
        #expect(values[0xF5] == nil)
        #expect(await fake.readCount(code: 0xF5) == 8, "4 attempts x 2 passes")
    }

    @Test("omits an unreadable code and never defaults it")
    func omitsUnreadable() async {
        let fake = FakeDDC(reads: [0xD7: [0]])   // 0xF5 has no script: noReply
        let reader = StableReader(sleep: instantSleeper(SleepLog()))

        let values = await reader.read(codes: [0xD7, 0xF5], from: fake)

        #expect(values == [0xD7: 0])
        #expect(!values.keys.contains(0xF5))
    }

    @Test("omits a code the display answers with a non-zero result code")
    func omitsUnsupported() async {
        actor Unsupported: DDCTransport {
            nonisolated let name = "unsupported"
            func write(_ write: VCPWrite) async throws {}
            func read(code: UInt8) async throws -> VCPReply {
                VCPReply(resultCode: 1, code: code, maximum: 0, current: 0)
            }
        }
        let reader = StableReader(sleep: instantSleeper(SleepLog()))
        let values = await reader.read(codes: [0xD7], from: Unsupported())
        #expect(values.isEmpty)
    }

    @Test("retries with the retry gap until every code is present")
    func retries() async {
        // 0xF5 fails for the first two reads (attempt 1), then reads 2 forever.
        let fake = FakeDDC(reads: [0xD7: [1], 0xF5: [nil, nil, 2]])
        let log = SleepLog()
        let reader = StableReader(sleep: instantSleeper(log), retryGap: .seconds(2))

        let values = await reader.read(codes: [0xD7, 0xF5], from: fake)

        #expect(values == [0xD7: 1, 0xF5: 2])
        #expect(await fake.readCount(code: 0xF5) == 4)
        #expect(await log.durations == [Timing.betweenDumps, .seconds(2), Timing.betweenDumps])
    }

    @Test("gives up after maxAttempts and returns the largest stable set")
    func givesUp() async {
        let fake = FakeDDC(reads: [0xD7: [nil, nil, 1], 0xF5: [nil]])
        let log = SleepLog()
        let reader = StableReader(sleep: instantSleeper(log), maxAttempts: 4, retryGap: .seconds(2))

        let values = await reader.read(codes: [0xD7, 0xF5], from: fake)

        #expect(values == [0xD7: 1])
        #expect(await fake.readCount(code: 0xD7) == 8)
        // 4 attempts: 4 between-dump gaps and 3 retry gaps, none after the last attempt.
        #expect(await log.durations.filter { $0 == .seconds(2) }.count == 3)
        #expect(await log.durations.filter { $0 == Timing.betweenDumps }.count == 4)
    }

    @Test("a read-only-unsupported transport yields nothing")
    func readUnsupported() async {
        let bridge = FakeDDC(name: "usb bridge", reads: [0xD7: [0]], supportsRead: false)
        let reader = StableReader(sleep: instantSleeper(SleepLog()))
        let values = await reader.read(codes: [0xD7], from: bridge)
        #expect(values.isEmpty)
        await #expect(throws: DDCError.readUnsupported) { try await bridge.read(code: 0xD7) }
    }
}

@Suite("FakeDDC")
struct FakeDDCTests {
    @Test("records writes in order")
    func recordsWrites() async throws {
        let fake = FakeDDC()
        try await fake.write(VCPWrite(code: 0xD7, value: 1))
        try await fake.write(VCPWrite(code: 0xD7, value: 0, source: .lgSideChannel))
        #expect(await fake.writes == [VCPWrite(code: 0xD7, value: 1), VCPWrite(code: 0xD7, value: 0, source: .lgSideChannel)])
    }

    @Test("queues drain to a sticky last value; nil throws noReply")
    func queues() async throws {
        let fake = FakeDDC(reads: [0xD7: [0, nil, 1]])
        #expect(try await fake.read(code: 0xD7).current == 0)
        await #expect(throws: DDCError.noReply) { try await fake.read(code: 0xD7) }
        #expect(try await fake.read(code: 0xD7).current == 1)
        #expect(try await fake.read(code: 0xD7).current == 1)
        await #expect(throws: DDCError.noReply) { try await fake.read(code: 0x60) }
        #expect(await fake.readRequests == [0xD7, 0xD7, 0xD7, 0xD7, 0x60])
    }

    @Test("Timing constants match the design")
    func timing() {
        #expect(Timing.settleAfterModeChange == .seconds(4))
        #expect(Timing.betweenDumps == .milliseconds(500))
        #expect(Timing.readRetryGap == .milliseconds(150))
        #expect(Timing.requestToReply == .milliseconds(50))
    }
}
