import Foundation

/// The parts of a 128-byte EDID base block this project needs. Pure parsing, no I/O.
public struct EDID: Sendable, Equatable, Hashable {
    public static let length = 128
    public static let header: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]

    /// Three-letter PNP manufacturer id from bytes 8-9 (big-endian, three 5-bit letters), e.g. "GSM".
    public let manufacturer: String
    /// Product code from bytes 10-11, little-endian.
    public let productCode: UInt16
    /// Numeric serial from bytes 12-15, little-endian. The LG USB bridge reports the same value.
    public let serial: UInt32
    /// Display name from descriptor 0xFC ("LG SDQHD" on the DualUp), or nil when absent.
    public let name: String?
    /// Serial string from descriptor 0xFF, or nil when absent.
    public let serialString: String?
    /// True when the base block's bytes sum to zero modulo 256.
    public let checksumValid: Bool
    /// The raw bytes that were parsed (base block plus any extensions).
    public let data: Data

    /// Parses an EDID. Throws `DDCError.invalidEDID` when shorter than 128 bytes or when the
    /// 8-byte header is wrong. A bad checksum is reported through `checksumValid`, not thrown.
    public static func parse(_ data: Data) throws -> EDID {
        let bytes = [UInt8](data)
        guard bytes.count >= length else {
            throw DDCError.invalidEDID("\(bytes.count) bytes, need at least \(length)")
        }
        guard Array(bytes[0..<8]) == header else {
            throw DDCError.invalidEDID("bad header \(hex(Array(bytes[0..<8])))")
        }

        let manufacturerBits = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        let manufacturer = String([
            letter((manufacturerBits >> 10) & 0x1F),
            letter((manufacturerBits >> 5) & 0x1F),
            letter(manufacturerBits & 0x1F),
        ])
        let productCode = UInt16(bytes[10]) | UInt16(bytes[11]) << 8
        let serial = UInt32(bytes[12]) | UInt32(bytes[13]) << 8 | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24
        let checksumValid = bytes[0..<length].reduce(0 as UInt8) { $0 &+ $1 } == 0

        return EDID(
            manufacturer: manufacturer,
            productCode: productCode,
            serial: serial,
            name: descriptorText(tag: 0xFC, in: bytes),
            serialString: descriptorText(tag: 0xFF, in: bytes),
            checksumValid: checksumValid,
            data: data
        )
    }

    /// Scans the four 18-byte descriptors at offsets 54, 72, 90 and 108 for a display
    /// descriptor (`00 00 00 tag`) and returns its 13-byte text, trimmed of the 0x0A terminator
    /// and padding, decoded as ISO Latin-1 (as the prototype does).
    static func descriptorText(tag: UInt8, in bytes: [UInt8]) -> String? {
        var offset = 54
        while offset + 18 <= 126, offset + 18 <= bytes.count {
            defer { offset += 18 }
            guard bytes[offset] == 0, bytes[offset + 1] == 0, bytes[offset + 3] == tag else { continue }
            let text = bytes[(offset + 5)..<(offset + 18)]
            let visible = text.prefix { $0 != 0x0A && $0 != 0x00 }
            guard let string = String(bytes: visible, encoding: .isoLatin1) else { return nil }
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func letter(_ value: UInt16) -> Character {
        guard (1...26).contains(value) else { return "?" }
        return Character(UnicodeScalar(UInt8(ascii: "A") + UInt8(value) - 1))
    }
}

extension EDID {
    /// Builds a minimal, checksummed 128-byte EDID. Used by tests; harmless to ship.
    public static func synthetic(
        manufacturer: String,
        productCode: UInt16,
        serial: UInt32,
        name: String?,
        serialString: String?
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        bytes.replaceSubrange(0..<8, with: header)

        let letters = Array(manufacturer.uppercased().unicodeScalars.prefix(3))
        var bits: UInt16 = 0
        for scalar in letters {
            let value = UInt16(scalar.value) - UInt16(UnicodeScalar("A").value) + 1
            bits = bits << 5 | (value & 0x1F)
        }
        bytes[8] = UInt8(bits >> 8)
        bytes[9] = UInt8(bits & 0xFF)
        bytes[10] = UInt8(productCode & 0xFF)
        bytes[11] = UInt8(productCode >> 8)
        bytes[12] = UInt8(serial & 0xFF)
        bytes[13] = UInt8((serial >> 8) & 0xFF)
        bytes[14] = UInt8((serial >> 16) & 0xFF)
        bytes[15] = UInt8((serial >> 24) & 0xFF)
        bytes[18] = 1   // EDID 1.4
        bytes[19] = 4

        var descriptor = 54
        func writeDescriptor(tag: UInt8, text: String) {
            bytes[descriptor + 3] = tag
            var textBytes = Array(text.utf8.prefix(13))
            if textBytes.count < 13 { textBytes.append(0x0A) }
            while textBytes.count < 13 { textBytes.append(0x20) }
            bytes.replaceSubrange((descriptor + 5)..<(descriptor + 18), with: textBytes)
            descriptor += 18
        }
        if let name { writeDescriptor(tag: 0xFC, text: name) }
        if let serialString { writeDescriptor(tag: 0xFF, text: serialString) }
        // Remaining descriptors: dummy (tag 0x10).
        while descriptor + 18 <= 126 {
            bytes[descriptor + 3] = 0x10
            descriptor += 18
        }

        let sum = bytes[0..<127].reduce(0 as UInt8) { $0 &+ $1 }
        bytes[127] = 0 &- sum
        return Data(bytes)
    }
}
