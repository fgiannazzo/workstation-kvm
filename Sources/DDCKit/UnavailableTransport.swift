/// A transport that is not configured. Every write throws `DDCError.bridgeNotFound` with the
/// reason; every read throws `DDCError.readUnsupported`. `LGDualUp` uses it as the USB bridge
/// when it is built with the video cable alone, so a `pbpOn` through such an instance fails
/// loudly instead of silently doing nothing.
public actor UnavailableTransport: DDCTransport {
    public nonisolated let name: String
    public let reason: String

    public init(name: String = "unavailable", reason: String) {
        self.name = name
        self.reason = reason
    }

    public func write(_ write: VCPWrite) async throws {
        throw DDCError.bridgeNotFound(reason)
    }

    public func read(code: UInt8) async throws -> VCPReply {
        throw DDCError.readUnsupported
    }
}
