import DDCKit
import Foundation
import Testing

@Suite("EDID parsing")
struct EDIDTests {
    static let dualUp = EDID.synthetic(manufacturer: "GSM", productCode: 0x7708, serial: 0x0001E240, name: "LG SDQHD", serialString: "312NTABC1234")

    @Test("synthetic EDID is 128 bytes with a valid checksum")
    func syntheticIsWellFormed() throws {
        let bytes = [UInt8](Self.dualUp)
        #expect(bytes.count == 128)
        #expect(bytes.reduce(0 as UInt8) { $0 &+ $1 } == 0)
        #expect(Array(bytes[0..<8]) == EDID.header)
        let parsed = try EDID.parse(Self.dualUp)
        #expect(parsed.checksumValid)
    }

    @Test("name comes from descriptor 0xFC, serial from bytes 12-15, serial string from 0xFF")
    func fields() throws {
        let parsed = try EDID.parse(Self.dualUp)
        #expect(parsed.name == "LG SDQHD")
        #expect(parsed.serial == 0x0001E240)
        #expect(parsed.serialString == "312NTABC1234")
        #expect(parsed.manufacturer == "GSM")
        #expect(parsed.productCode == 0x7708)
        #expect(parsed.data == Self.dualUp)
    }

    @Test("ExternalDisplay is built from the parsed EDID")
    func externalDisplay() throws {
        let display = ExternalDisplay(edid: try EDID.parse(Self.dualUp))
        #expect(display.name == "LG SDQHD")
        #expect(display.serial == 0x0001E240)
        #expect(display.serialHex == "0x0001E240")
        #expect(display.serialString == "312NTABC1234")
        #expect(display.manufacturer == "GSM")
        #expect(display.productCode == 0x7708)
        #expect(display.nameContains("sdqhd"))
        #expect(display.nameContains("SDQHD"))
        #expect(!display.nameContains("4K"))
        #expect(display.description.contains("LG SDQHD"))
        #expect(display.description.contains("0x0001E240"))
        #expect(display.description.contains("312NTABC1234"))
    }

    @Test("the name descriptor is found at any of the four offsets")
    func nameAtLaterOffset() throws {
        // Serial string first (offset 54), then name (offset 72).
        var bytes = [UInt8](EDID.synthetic(manufacturer: "GSM", productCode: 1, serial: 7, name: nil, serialString: "ABC"))
        bytes[72 + 3] = 0xFC
        let text = Array("LG HDR 4K\n   ".utf8)
        bytes.replaceSubrange((72 + 5)..<(72 + 18), with: text)
        bytes[127] = 0 &- bytes[0..<127].reduce(0 as UInt8) { $0 &+ $1 }
        let parsed = try EDID.parse(Data(bytes))
        #expect(parsed.name == "LG HDR 4K")
        #expect(parsed.serialString == "ABC")
        #expect(parsed.checksumValid)
    }

    @Test("missing descriptors are nil")
    func missingDescriptors() throws {
        let parsed = try EDID.parse(EDID.synthetic(manufacturer: "SAM", productCode: 2, serial: 0, name: nil, serialString: nil))
        #expect(parsed.name == nil)
        #expect(parsed.serialString == nil)
        #expect(parsed.manufacturer == "SAM")
        let display = ExternalDisplay(edid: parsed)
        #expect(display.name == "(no name)")
    }

    @Test("a bad checksum is reported, not thrown")
    func badChecksum() throws {
        var bytes = [UInt8](Self.dualUp)
        bytes[127] &+= 1
        let parsed = try EDID.parse(Data(bytes))
        #expect(!parsed.checksumValid)
        #expect(parsed.name == "LG SDQHD")
    }

    @Test("short data and a bad header throw invalidEDID")
    func invalid() {
        #expect(throws: DDCError.self) { try EDID.parse(Data([UInt8](repeating: 0, count: 64))) }
        var bytes = [UInt8](Self.dualUp)
        bytes[0] = 0xFF
        #expect(throws: DDCError.self) { try EDID.parse(Data(bytes)) }
    }
}
