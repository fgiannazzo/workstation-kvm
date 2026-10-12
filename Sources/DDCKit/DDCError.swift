import Foundation

public enum DDCError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No external display's EDID name contains the given substring.
    case displayNotFound(String)
    /// An IOKit call failed. `code` is the raw `IOReturn`/`kern_return_t`.
    case ioKit(Int32, operation: String)
    /// The 12-byte reply did not have 0x02 at byte 2, or was too short. Carries the raw bytes.
    case invalidReply([UInt8])
    /// The transport cannot read (the LG USB bridge never answers reads).
    case readUnsupported
    /// The display did not answer within the retry budget.
    case noReply
    /// The EDID could not be parsed. Carries the reason.
    case invalidEDID(String)

    public var description: String {
        switch self {
        case .displayNotFound(let name):
            return "no external display matches \"\(name)\""
        case .ioKit(let code, let operation):
            return "\(operation) failed: IOKit error 0x\(String(UInt32(bitPattern: code), radix: 16, uppercase: true))"
        case .invalidReply(let bytes):
            return "invalid DDC reply: \(hex(bytes))"
        case .readUnsupported:
            return "this transport cannot read"
        case .noReply:
            return "no reply from the display"
        case .invalidEDID(let reason):
            return "invalid EDID: \(reason)"
        }
    }
}
