import Foundation

/// An external display found through IOKit, identified by its EDID (never by its index: the
/// order changes when a display re-enumerates).
public struct ExternalDisplay: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// Display name from EDID descriptor 0xFC, e.g. "LG SDQHD". "(no name)" when absent,
    /// "(no EDID)" when the EDID could not be read at all.
    public let name: String
    /// Numeric serial, EDID bytes 12-15 little-endian. Pairs the display with its USB bridge.
    public let serial: UInt32
    /// Serial string from EDID descriptor 0xFF, when present.
    public let serialString: String?
    /// Three-letter PNP manufacturer id, e.g. "GSM" for LG.
    public let manufacturer: String
    /// EDID product code.
    public let productCode: UInt16
    /// The raw EDID (empty when it could not be read).
    public let edid: Data

    public init(name: String, serial: UInt32, serialString: String?, manufacturer: String, productCode: UInt16, edid: Data) {
        self.name = name
        self.serial = serial
        self.serialString = serialString
        self.manufacturer = manufacturer
        self.productCode = productCode
        self.edid = edid
    }

    public init(edid parsed: EDID) {
        self.init(
            name: parsed.name ?? "(no name)",
            serial: parsed.serial,
            serialString: parsed.serialString,
            manufacturer: parsed.manufacturer,
            productCode: parsed.productCode,
            edid: parsed.data
        )
    }

    /// A display whose EDID could not be read or parsed.
    public static func withoutEDID() -> ExternalDisplay {
        ExternalDisplay(name: "(no EDID)", serial: 0, serialString: nil, manufacturer: "???", productCode: 0, edid: Data())
    }

    /// Case-insensitive substring match on the EDID name, the way the prototype selects a display.
    public func nameContains(_ substring: String) -> Bool {
        name.lowercased().contains(substring.lowercased())
    }

    /// Serial as 8 upper-case hex digits with a 0x prefix.
    public var serialHex: String {
        "0x" + String(serial, radix: 16, uppercase: true).leftPadded(to: 8)
    }

    public var description: String {
        var parts = ["\(name)", "serial \(serialHex)"]
        if let serialString, !serialString.isEmpty { parts.append("serial string \(serialString)") }
        parts.append("\(manufacturer) 0x\(String(productCode, radix: 16, uppercase: true).leftPadded(to: 4))")
        return parts.joined(separator: "  ")
    }
}

/// Enumerates the external displays reachable through IOAVService.
public enum DisplayEnumerator {
    /// Every `DCPAVServiceProxy` with `Location == External`, named from its EDID.
    public static func externalDisplays() throws -> [ExternalDisplay] {
        try IOAVServices.externalEntries().map(\.display)
    }
}

extension String {
    func leftPadded(to width: Int, with pad: Character = "0") -> String {
        count >= width ? self : String(repeating: pad, count: width - count) + self
    }
}
