import DDCKit
import SwitchboardCore

/// The LG DualUp's VCP codes this project reads (brief, section 3).
public enum DualUpCode {
    /// Picture-by-picture: 0 = on, 1 = off.
    public static let pbp: UInt8 = 0xD7
    /// Main input: 1 = HDMI 1, 2 = HDMI 2. Flips on a main/sub swap.
    public static let mainInput: UInt8 = 0xF5

    /// Everything `readState()` asks for.
    public static let stateCodes: [UInt8] = [pbp, mainInput]
}

/// One read of the DualUp's state. Codes the display did not answer stably are `unknown`;
/// `raw` holds only the codes that were read.
///
/// JSON: `{"pbp": "off", "mainInput": "hdmi1", "raw": {"0xD7": 1, "0xF5": 1}}`. `raw` is an
/// object keyed by the code in hex, and `pbp`/`mainInput` are re-derived from it on decode.
public struct DualUpReading: Sendable, Equatable, Codable {
    public let pbp: PBPState
    public let mainInput: MainInput
    public let raw: [UInt8: UInt16]

    public init(raw: [UInt8: UInt16]) {
        self.raw = raw
        self.pbp = Self.pbpState(from: raw[DualUpCode.pbp])
        self.mainInput = Self.mainInput(from: raw[DualUpCode.mainInput])
    }

    /// 0xD7: 0 = on, 1 = off, anything else or missing = unknown.
    public static func pbpState(from value: UInt16?) -> PBPState {
        switch value {
        case 0: return .on
        case 1: return .off
        default: return .unknown
        }
    }

    /// 0xF5: 1 = HDMI 1, 2 = HDMI 2, anything else or missing = unknown.
    public static func mainInput(from value: UInt16?) -> MainInput {
        switch value {
        case 1: return .hdmi1
        case 2: return .hdmi2
        default: return .unknown
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case pbp, mainInput, raw }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keyed = try container.decode([String: UInt16].self, forKey: .raw)
        var raw: [UInt8: UInt16] = [:]
        for (key, value) in keyed {
            guard let code = Self.code(fromKey: key) else {
                throw DecodingError.dataCorruptedError(forKey: .raw, in: container, debugDescription: "raw key \"\(key)\" is not a VCP code like \"0xD7\"")
            }
            raw[code] = value
        }
        self.init(raw: raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pbp, forKey: .pbp)
        try container.encode(mainInput, forKey: .mainInput)
        var keyed: [String: UInt16] = [:]
        for (code, value) in raw { keyed[Self.key(for: code)] = value }
        try container.encode(keyed, forKey: .raw)
    }

    /// "0xD7" for 0xD7.
    public static func key(for code: UInt8) -> String {
        "0x" + DDCPacket.hexString([code])
    }

    static func code(fromKey key: String) -> UInt8? {
        var digits = key.lowercased()
        if digits.hasPrefix("0x") { digits.removeFirst(2) }
        return UInt8(digits, radix: 16)
    }
}

/// The LG DualUp 28MQ780.
///
/// Reads go over the video cable (`readState`). Writes are the two `LGDualUpCommand` cases,
/// each on its own transport, and every write is followed by a settle wait and a video-cable
/// read-back (`perform`); the write alone never counts as success.
public actor LGDualUp {
    /// DDC/CI over the video cable: the only transport that answers reads.
    public nonisolated let videoCable: any DDCTransport
    /// The monitor's USB HID bridge: write-only, carries `pbpOn`.
    public nonisolated let usbBridge: any DDCTransport
    private let reader: StableReader
    private let sleep: Sleeper

    public init(videoCable: any DDCTransport, usbBridge: any DDCTransport, sleep: @escaping Sleeper = Timing.realSleep) {
        self.videoCable = videoCable
        self.usbBridge = usbBridge
        self.reader = StableReader(sleep: sleep)
        self.sleep = sleep
    }

    /// Video cable only. `perform(.pbpOn)` through this instance throws `DDCError.bridgeNotFound`.
    public init(videoCable: any DDCTransport, sleep: @escaping Sleeper = Timing.realSleep) {
        self.init(
            videoCable: videoCable,
            usbBridge: UnavailableTransport(name: "USB bridge (not configured)", reason: "this LGDualUp was built without a USB bridge transport"),
            sleep: sleep
        )
    }

    /// Reads 0xD7 and 0xF5 with settle-and-double-dump. Never throws: a code that cannot be
    /// read stably is reported as `unknown`, not defaulted and not as a failure of the monitor.
    public func readState() async -> DualUpReading {
        let raw = await reader.read(codes: DualUpCode.stateCodes, from: videoCable)
        return DualUpReading(raw: raw)
    }

    /// Write, settle, double-read, compare. The write goes to the command's transport; a write
    /// error propagates. Then `Timing.settleAfterModeChange` (the link re-trains after a PBP
    /// change), then `StableReader` reads 0xD7 and 0xF5 over the video cable. An unreadable
    /// 0xD7 is not an error: `observed == nil`, `verified == false`.
    public func perform(_ command: LGDualUpCommand) async throws -> WriteOutcome {
        let transport = transport(for: command.transport)
        try await transport.write(command.write)
        await sleep(Timing.settleAfterModeChange)

        let raw = await reader.read(codes: DualUpCode.stateCodes, from: videoCable)
        let observed = raw[command.code]
        return WriteOutcome(
            command: command,
            transport: transport.name,
            expected: command.expectedReadBack,
            observed: observed,
            verified: observed == command.expectedReadBack,
            reading: DualUpReading(raw: raw)
        )
    }

    private func transport(for kind: LGDualUpTransport) -> any DDCTransport {
        switch kind {
        case .usbBridge: return usbBridge
        case .videoCable: return videoCable
        }
    }
}
