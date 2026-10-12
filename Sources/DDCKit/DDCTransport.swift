/// One way to reach the display's DDC/CI endpoint. Implementations are actors.
///
/// - `VideoCableDDC`: IOAVService over the video cable; reads and writes.
/// - `LGUSBBridge` (tracer bullet 2): IOHIDManager; write-only, `read` throws `DDCError.readUnsupported`.
/// - `FakeDDC`: records writes and serves scripted reads, for tests.
public protocol DDCTransport: Sendable {
    /// Human-readable transport name for logs and `WriteOutcome`, e.g. "video cable (SDQHD)".
    var name: String { get }

    /// Sends one VCP set. Never report success from this alone: verify with a read afterwards.
    func write(_ write: VCPWrite) async throws

    /// Sends one VCP get and decodes the reply. Retries inside the transport; throws
    /// `DDCError.noReply` when the retry budget is exhausted.
    func read(code: UInt8) async throws -> VCPReply
}
