/// Pure DDC/CI packet encoders. No I/O. Tested against the byte vectors in `docs/DESIGN.md`.
///
/// Every packet is `length-byte, payload..., checksum` where the length byte is `0x80 | n`
/// (n = payload length) and the checksum is XOR over `0x6E`, the source address and the bytes
/// before it.
public enum DDCPacket {
    /// Destination address of a DDC/CI transaction as seen by the checksum (the display's
    /// I2C address 0x37 shifted left by one).
    public static let destinationAddress: UInt8 = 0x6E

    /// The I2C chip address of the display's DDC/CI endpoint.
    public static let i2cAddress: UInt32 = 0x37

    /// XOR over `0x6E`, `source` and `bytes`.
    public static func checksum(source: UInt8, bytes: [UInt8]) -> UInt8 {
        bytes.reduce(destinationAddress ^ source) { $0 ^ $1 }
    }

    /// VCP set: `84 03 code hi lo chk`.
    public static func vcpSet(code: UInt8, value: UInt16, source: DDCSource = .standard) -> [UInt8] {
        let body: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        return body + [checksum(source: source.rawValue, bytes: body)]
    }

    /// VCP set from a `VCPWrite`, using the write's own source.
    public static func vcpSet(_ write: VCPWrite) -> [UInt8] {
        vcpSet(code: write.code, value: write.value, source: write.source)
    }

    /// VCP get request: `82 01 code chk`. Followed on the wire by a 12-byte read (`VCPReply`).
    public static func vcpGet(code: UInt8, source: DDCSource = .standard) -> [UInt8] {
        let body: [UInt8] = [0x82, 0x01, code]
        return body + [checksum(source: source.rawValue, bytes: body)]
    }

    /// Capabilities string fragment request: `83 F3 offset_hi offset_lo chk`.
    public static func capabilitiesRequest(offset: UInt16, source: DDCSource = .standard) -> [UInt8] {
        let body: [UInt8] = [0x83, 0xF3, UInt8(offset >> 8), UInt8(offset & 0xFF)]
        return body + [checksum(source: source.rawValue, bytes: body)]
    }

    /// Size of every report on the LG USB HID bridge.
    public static let usbReportLength = 64

    /// The two 64-byte output reports that carry one VCP set over the LG USB HID bridge
    /// (brief, section 3): header `08 01 55 03 LEN 00 03 37`, then the DDC packet
    /// `51 84 03 code hi lo chk` (LEN = its length, 7), zero padded. The follow-up is the same
    /// report with byte 1 = 0x02, byte 3 = 0x04, byte 4 = 0x0B and byte 6 = 0x0B.
    ///
    /// Encoder only. The transport that sends these (`LGUSBBridge`) is tracer bullet 2.
    public static func usbBridgeReports(set code: UInt8, value: UInt16) -> (first: [UInt8], second: [UInt8]) {
        let ddc = [DDCSource.standard.rawValue] + vcpSet(code: code, value: value, source: .standard)
        var first: [UInt8] = [0x08, 0x01, 0x55, 0x03, UInt8(ddc.count), 0x00, 0x03, UInt8(i2cAddress)]
        first += ddc
        first += [UInt8](repeating: 0, count: usbReportLength - first.count)

        var second = first
        second[1] = 0x02
        second[3] = 0x04
        second[4] = 0x0B
        second[6] = 0x0B
        return (first, second)
    }
}
