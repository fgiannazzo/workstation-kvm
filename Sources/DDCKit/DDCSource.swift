/// DDC/CI source address written into the I2C transaction and folded into the checksum.
public enum DDCSource: UInt8, Sendable, Codable, CaseIterable, Hashable {
    /// The standard host address. Every read and every ordinary write uses it.
    case standard = 0x51
    /// LG's side channel. Accepts writes, never answers reads. Only 0xD7 may ever be sent
    /// there, and never 0xF4 (brief, section 3).
    case lgSideChannel = 0x50
}

/// A raw VCP write. The initialiser is `package`-scoped: only targets inside this package can
/// construct one, and by rule only `Devices.LGDualUpCommand` does (plus the test targets).
/// Outside the package a write that is not in the whitelist cannot be expressed.
public struct VCPWrite: Sendable, Equatable, Hashable, CustomStringConvertible {
    public let code: UInt8
    public let value: UInt16
    public let source: DDCSource

    package init(code: UInt8, value: UInt16, source: DDCSource = .standard) {
        self.code = code
        self.value = value
        self.source = source
    }

    public var description: String {
        "VCPWrite(0x\(hex(code)) = \(value), source 0x\(hex(source.rawValue)))"
    }
}

/// Upper-case two-digit hex, the way the brief writes bytes.
func hex(_ byte: UInt8) -> String {
    let digits = Array("0123456789ABCDEF")
    return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { hex($0) }.joined(separator: " ")
}
