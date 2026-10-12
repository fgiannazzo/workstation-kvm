/// Test double for `DDCTransport`. Records every write and serves scripted reads.
///
/// Reads are queues per code: each `read(code:)` consumes the next entry; `nil` throws
/// `DDCError.noReply`. When a queue is down to its last entry that entry is sticky, so a code
/// scripted `[1]` reads 1 forever and one scripted `[1, nil]` reads 1 once and then fails
/// forever. A code with no queue throws `DDCError.noReply`.
public actor FakeDDC: DDCTransport {
    public nonisolated let name: String
    /// False models the LG USB bridge, which never answers reads (`DDCError.readUnsupported`).
    public let supportsRead: Bool

    public private(set) var writes: [VCPWrite] = []
    /// Every code that was asked for, in order, including failed reads.
    public private(set) var readRequests: [UInt8] = []
    private var reads: [UInt8: [UInt16?]]
    private let maximum: UInt16

    public init(name: String = "fake", reads: [UInt8: [UInt16?]] = [:], supportsRead: Bool = true, maximum: UInt16 = 0xFF) {
        self.name = name
        self.reads = reads
        self.supportsRead = supportsRead
        self.maximum = maximum
    }

    /// Appends scripted values to a code's queue.
    public func enqueue(code: UInt8, _ values: [UInt16?]) {
        reads[code, default: []] += values
    }

    /// Replaces a code's queue.
    public func script(code: UInt8, _ values: [UInt16?]) {
        reads[code] = values
    }

    public func write(_ write: VCPWrite) async throws {
        writes.append(write)
    }

    public func read(code: UInt8) async throws -> VCPReply {
        readRequests.append(code)
        guard supportsRead else { throw DDCError.readUnsupported }
        guard var queue = reads[code], !queue.isEmpty else { throw DDCError.noReply }
        let next = queue.count == 1 ? queue[0] : queue.removeFirst()
        reads[code] = queue
        guard let value = next else { throw DDCError.noReply }
        return VCPReply(resultCode: 0, code: code, maximum: maximum, current: value)
    }

    /// Number of reads requested for one code.
    public func readCount(code: UInt8) -> Int {
        readRequests.filter { $0 == code }.count
    }
}
