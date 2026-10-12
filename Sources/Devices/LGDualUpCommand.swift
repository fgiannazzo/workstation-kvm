import DDCKit
import SwitchboardCore

/// Which of the DualUp's two DDC/CI paths a command goes out on.
public enum LGDualUpTransport: String, Sendable, Codable, CaseIterable, Hashable {
    /// The monitor's USB HID bridge (`LGUSBBridge`). Write-only.
    case usbBridge
    /// DDC/CI over the video cable (`VideoCableDDC`), source 0x51.
    case videoCable
}

/// The whitelist. These two cases are the only hardware writes in the codebase (brief,
/// section 3, "The DualUp's PBP code, 0xD7"; `CLAUDE.md`). Adding a case needs a verified fact
/// in `docs/BRIEF.md` first. Nothing else in the package constructs a `VCPWrite`.
///
/// | Command  | Transport   | Write     | Read-back on the video cable |
/// |----------|-------------|-----------|------------------------------|
/// | `pbpOn`  | USB bridge  | 0xD7 = 0  | 0                            |
/// | `pbpOff` | video cable | 0xD7 = 1  | 1                            |
///
/// The opposite value on each transport is accepted on the wire and ignored, which is why the
/// transport is part of the command and not a caller's choice.
public enum LGDualUpCommand: String, CaseIterable, Sendable, Codable, Hashable {
    /// PBP on: stacked split, each half a 2560 x 1440 display. USB bridge only.
    case pbpOn
    /// PBP off. Video cable only.
    case pbpOff

    /// Always 0xD7 today.
    public var code: UInt8 { DualUpCode.pbp }

    /// 0 for on, 1 for off.
    public var value: UInt16 {
        switch self {
        case .pbpOn: return 0
        case .pbpOff: return 1
        }
    }

    public var transport: LGDualUpTransport {
        switch self {
        case .pbpOn: return .usbBridge
        case .pbpOff: return .videoCable
        }
    }

    /// What 0xD7 reads back on the video cable once the write took effect.
    public var expectedReadBack: UInt16 { value }

    /// The PBP state the command is meant to produce.
    public var targetState: PBPState {
        switch self {
        case .pbpOn: return .on
        case .pbpOff: return .off
        }
    }

    /// The raw write, always on source 0x51. `package`: only this package can turn a command
    /// into bytes, and only `LGDualUp.perform` does.
    package var write: VCPWrite {
        VCPWrite(code: code, value: value, source: .standard)
    }
}

/// What `LGDualUp.perform` reports. `verified` is true only when the video-cable read-back
/// agreed with the command's expectation twice; `observed == nil` means 0xD7 could not be read
/// stably, which is "unverified", never "the monitor failed".
public struct WriteOutcome: Sendable, Equatable, Codable {
    public let command: LGDualUpCommand
    /// `DDCTransport.name` of the transport that carried the write.
    public let transport: String
    public let expected: UInt16
    public let observed: UInt16?
    public let verified: Bool
    /// The full post-write read (0xD7 and 0xF5), so callers can refresh state from it.
    public let reading: DualUpReading

    public init(command: LGDualUpCommand, transport: String, expected: UInt16, observed: UInt16?, verified: Bool, reading: DualUpReading) {
        self.command = command
        self.transport = transport
        self.expected = expected
        self.observed = observed
        self.verified = verified
        self.reading = reading
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case command, transport, expected, observed, verified, reading }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            command: try container.decode(LGDualUpCommand.self, forKey: .command),
            transport: try container.decode(String.self, forKey: .transport),
            expected: try container.decode(UInt16.self, forKey: .expected),
            observed: try container.decodeIfPresent(UInt16.self, forKey: .observed),
            verified: try container.decode(Bool.self, forKey: .verified),
            reading: try container.decode(DualUpReading.self, forKey: .reading)
        )
    }

    /// `observed` is written as an explicit `null` when unreadable, so JSON consumers see the
    /// "unverified because unreadable" case rather than a missing key.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(command, forKey: .command)
        try container.encode(transport, forKey: .transport)
        try container.encode(expected, forKey: .expected)
        try container.encode(observed, forKey: .observed)
        try container.encode(verified, forKey: .verified)
        try container.encode(reading, forKey: .reading)
    }
}

/// Renders exactly what `LGDualUp.perform` would put on the wire for a command, without
/// touching any transport. `switchboardctl monitor pbp ... --dry-run` prints these lines.
public enum DryRunFormatter {
    public static func lines(for command: LGDualUpCommand, displayNameContains: String) -> [String] {
        let write = command.write
        var lines = [
            "dry run: \(command.rawValue), nothing is sent",
            "display: EDID name contains \"\(displayNameContains)\"",
            "write: VCP 0x\(hex(write.code)) = \(write.value), source 0x\(hex(write.source.rawValue))",
        ]
        switch command.transport {
        case .usbBridge:
            let (first, second) = DDCPacket.usbBridgeReports(set: write.code, value: write.value)
            lines.append("transport: USB bridge, IOHIDDeviceSetReport(output, report id \(LGUSBBridge.reportID), \(DDCPacket.usbReportLength) bytes) twice")
            lines.append("report 1: \(DDCPacket.hexString(first))")
            lines.append("report 2: \(DDCPacket.hexString(second))")
        case .videoCable:
            let packet = DDCPacket.vcpSet(write)
            lines.append("transport: video cable, IOAVServiceWriteI2C(chip 0x37, source 0x\(hex(write.source.rawValue)), \(packet.count) bytes)")
            lines.append("packet: \(DDCPacket.hexString(packet))")
        }
        lines.append("then: wait \(Timing.settleAfterModeChange) and read 0x\(hex(command.code)) twice over the video cable; verified when both read \(command.expectedReadBack) (\(command.targetState.rawValue))")
        return lines
    }

    private static func hex(_ byte: UInt8) -> String {
        DDCPacket.hexString([byte])
    }
}
