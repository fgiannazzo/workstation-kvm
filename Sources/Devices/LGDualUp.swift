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
public struct DualUpReading: Sendable, Equatable {
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
}

/// The LG DualUp 28MQ780.
///
/// Tracer bullet 1: reads only. Tracer bullet 2 adds the `usbBridge` transport, the
/// `LGDualUpCommand` whitelist and `perform(_:)` with its verify-after-write flow
/// (`docs/DESIGN.md`, "Devices.LGDualUp"). Until then there is no write path in this type.
public actor LGDualUp {
    /// DDC/CI over the video cable: the only transport that answers reads.
    public let videoCable: any DDCTransport
    private let reader: StableReader

    public init(videoCable: any DDCTransport, sleep: @escaping Sleeper = Timing.realSleep) {
        self.videoCable = videoCable
        self.reader = StableReader(sleep: sleep)
    }

    /// Reads 0xD7 and 0xF5 with settle-and-double-dump. Never throws: a code that cannot be
    /// read stably is reported as `unknown`, not defaulted and not as a failure of the monitor.
    public func readState() async -> DualUpReading {
        let raw = await reader.read(codes: DualUpCode.stateCodes, from: videoCable)
        return DualUpReading(raw: raw)
    }

    // Tracer bullet 2 adds here:
    //   public let usbBridge: any DDCTransport
    //   public func perform(_ command: LGDualUpCommand) async throws -> WriteOutcome
}
