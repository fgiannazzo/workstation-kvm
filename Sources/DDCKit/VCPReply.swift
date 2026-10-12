/// The 12-byte reply read after a VCP get request.
///
/// Layout: `bytes[2] == 0x02` (else the reply is invalid); `bytes[3]` = result code (0 = ok);
/// `bytes[4]` = the VCP code; `bytes[6..7]` = maximum; `bytes[8..9]` = current value.
public struct VCPReply: Sendable, Equatable, Hashable, CustomStringConvertible {
    public static let length = 12

    /// 0 means the display answered the code; anything else is preserved for the caller.
    public let resultCode: UInt8
    public let code: UInt8
    public let maximum: UInt16
    public let current: UInt16

    public init(resultCode: UInt8, code: UInt8, maximum: UInt16, current: UInt16) {
        self.resultCode = resultCode
        self.code = code
        self.maximum = maximum
        self.current = current
    }

    /// Decodes the raw I2C read. Throws `DDCError.invalidReply` when the buffer is shorter than
    /// 12 bytes or byte 2 is not 0x02. A non-zero result code is not an error here.
    public init(bytes: [UInt8]) throws {
        guard bytes.count >= Self.length, bytes[2] == 0x02 else {
            throw DDCError.invalidReply(bytes)
        }
        resultCode = bytes[3]
        code = bytes[4]
        maximum = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        current = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
    }

    /// True when the display reported the code as supported (result code 0).
    public var isOK: Bool { resultCode == 0 }

    public var description: String {
        "0x\(hex(code)) cur=\(current) max=\(maximum) rc=\(resultCode)"
    }
}
