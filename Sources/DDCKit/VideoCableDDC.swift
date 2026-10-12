import Foundation

/// DDC/CI over the video cable through the private IOAVService API.
///
/// The display is selected by a substring of its EDID name and re-resolved on every operation:
/// the IOKit enumeration order changes when a display re-enumerates (which the DualUp does on
/// every PBP change), so an index or a cached service would silently point at another display.
public actor VideoCableDDC: DDCTransport {
    public nonisolated let name: String
    /// Case-insensitive substring of the EDID name, "SDQHD" for the LG DualUp.
    public let displayNameContains: String

    private let sleep: Sleeper
    private let readAttempts = 3

    public init(displayNameContains: String = "SDQHD", sleep: @escaping Sleeper = Timing.realSleep) {
        self.displayNameContains = displayNameContains
        self.name = "video cable (\(displayNameContains))"
        self.sleep = sleep
    }

    /// Resolves the display now. Throws `DDCError.displayNotFound` when it is not connected.
    public func display() throws -> ExternalDisplay {
        try IOAVServices.resolve(nameContains: displayNameContains).display
    }

    /// Sends `82 01 code chk` on source 0x51, waits `Timing.requestToReply`, reads 12 bytes.
    /// Up to three attempts, `Timing.readRetryGap` apart. The last error is rethrown.
    public func read(code: UInt8) async throws -> VCPReply {
        let service = try IOAVServices.resolve(nameContains: displayNameContains).service
        let request = DDCPacket.vcpGet(code: code, source: .standard)
        var lastError: any Error = DDCError.noReply

        for attempt in 0..<readAttempts {
            if attempt > 0 { await sleep(Timing.readRetryGap) }
            do {
                try service.writeI2C(chip: DDCPacket.i2cAddress, source: DDCSource.standard.rawValue, bytes: request)
                await sleep(Timing.requestToReply)
                let bytes = try service.readI2C(chip: DDCPacket.i2cAddress, source: DDCSource.standard.rawValue, length: VCPReply.length)
                return try VCPReply(bytes: bytes)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Sends `84 03 code hi lo chk` on the write's source. Required by `DDCTransport`; nothing
    /// outside tests constructs a `VCPWrite` until `Devices.LGDualUp` gains its whitelist in
    /// tracer bullet 2. Never report success from this call: verify with `read(code:)`.
    public func write(_ write: VCPWrite) async throws {
        let service = try IOAVServices.resolve(nameContains: displayNameContains).service
        try service.writeI2C(chip: DDCPacket.i2cAddress, source: write.source.rawValue, bytes: DDCPacket.vcpSet(write))
    }

    /// Reads the capabilities string: `83 F3 offset chk` requests, 64-byte fragment reads until a
    /// zero-length fragment. Read-only; diagnostics. The DualUp reports `model(MQ750)` and the
    /// manufacturer codes listed in the brief.
    public func capabilities() async throws -> String {
        let service = try IOAVServices.resolve(nameContains: displayNameContains).service
        var offset: UInt16 = 0
        var payload: [UInt8] = []
        let maxFragments = 64

        for _ in 0..<maxFragments {
            let request = DDCPacket.capabilitiesRequest(offset: offset, source: .standard)
            try service.writeI2C(chip: DDCPacket.i2cAddress, source: DDCSource.standard.rawValue, bytes: request)
            await sleep(Timing.requestToReply)
            let bytes = try service.readI2C(chip: DDCPacket.i2cAddress, source: DDCSource.standard.rawValue, length: 64)

            // Reply: 6E, 0x80|n, E3, offset_hi, offset_lo, data[n-3], chk
            guard bytes.count >= 6, bytes[2] == 0xE3 else { throw DDCError.invalidReply(bytes) }
            let n = Int(bytes[1] & 0x7F)
            guard n > 3, 5 + (n - 3) <= bytes.count else { break }   // zero-length fragment: done
            let fragment = Array(bytes[5..<(5 + n - 3)])
            payload += fragment
            offset &+= UInt16(fragment.count)
        }
        return String(decoding: payload, as: UTF8.self)
    }
}
