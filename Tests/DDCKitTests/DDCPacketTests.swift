import DDCKit
import Testing

/// Every byte vector from docs/DESIGN.md, "DDCKit".
@Suite("DDCPacket encoders")
struct DDCPacketTests {
    @Test("checksum is XOR over 0x6E, source and bytes")
    func checksum() {
        #expect(DDCPacket.checksum(source: 0x51, bytes: []) == 0x6E ^ 0x51)
        #expect(DDCPacket.checksum(source: 0x51, bytes: [0x84, 0x03, 0xD7, 0x00, 0x01]) == 0x6E)
        #expect(DDCPacket.checksum(source: 0x50, bytes: [0x84, 0x03, 0xD7, 0x00, 0x01]) == 0x6F)
        #expect(DDCPacket.checksum(source: 0x51, bytes: [0x82, 0x01, 0xD7]) == 0x6B)
    }

    @Test("VCP set 0xD7 = 1, source 0x51")
    func setPBPOff() {
        #expect(DDCPacket.vcpSet(code: 0xD7, value: 1, source: .standard) == [0x84, 0x03, 0xD7, 0x00, 0x01, 0x6E])
        #expect(DDCPacket.vcpSet(code: 0xD7, value: 1) == [0x84, 0x03, 0xD7, 0x00, 0x01, 0x6E])
    }

    @Test("VCP set 0xD7 = 0, source 0x51")
    func setPBPOn() {
        #expect(DDCPacket.vcpSet(code: 0xD7, value: 0, source: .standard) == [0x84, 0x03, 0xD7, 0x00, 0x00, 0x6F])
    }

    @Test("VCP set 0xD7 = 1, source 0x50 (encoder only; never sent today)")
    func setSideChannel() {
        #expect(DDCPacket.vcpSet(code: 0xD7, value: 1, source: .lgSideChannel) == [0x84, 0x03, 0xD7, 0x00, 0x01, 0x6F])
    }

    @Test("VCP set splits a 16-bit value big-endian")
    func setWideValue() {
        let packet = DDCPacket.vcpSet(code: 0x60, value: 0x1234, source: .standard)
        #expect(Array(packet[0..<5]) == [0x84, 0x03, 0x60, 0x12, 0x34])
        #expect(packet[5] == DDCPacket.checksum(source: 0x51, bytes: Array(packet[0..<5])))
    }

    @Test("VCP get 0xD7 and 0xF5, source 0x51")
    func getRequests() {
        #expect(DDCPacket.vcpGet(code: 0xD7, source: .standard) == [0x82, 0x01, 0xD7, 0x6B])
        #expect(DDCPacket.vcpGet(code: 0xF5, source: .standard) == [0x82, 0x01, 0xF5, 0x49])
        #expect(DDCPacket.vcpGet(code: 0xF5) == [0x82, 0x01, 0xF5, 0x49])
    }

    @Test("capabilities fragment request at offset 0, source 0x51")
    func capabilitiesRequest() {
        #expect(DDCPacket.capabilitiesRequest(offset: 0, source: .standard) == [0x83, 0xF3, 0x00, 0x00, 0x4F])
        let later = DDCPacket.capabilitiesRequest(offset: 0x0120, source: .standard)
        #expect(Array(later[0..<4]) == [0x83, 0xF3, 0x01, 0x20])
        #expect(later[4] == DDCPacket.checksum(source: 0x51, bytes: [0x83, 0xF3, 0x01, 0x20]))
    }

    @Test("USB bridge reports for set 0xD7 = 0")
    func usbBridgeReports() {
        let (first, second) = DDCPacket.usbBridgeReports(set: 0xD7, value: 0)

        #expect(first.count == 64)
        #expect(second.count == 64)

        let expectedFirst: [UInt8] = [0x08, 0x01, 0x55, 0x03, 0x07, 0x00, 0x03, 0x37, 0x51, 0x84, 0x03, 0xD7, 0x00, 0x00, 0x6F]
        let expectedSecond: [UInt8] = [0x08, 0x02, 0x55, 0x04, 0x0B, 0x00, 0x0B, 0x37, 0x51, 0x84, 0x03, 0xD7, 0x00, 0x00, 0x6F]
        #expect(Array(first[0..<15]) == expectedFirst)
        #expect(Array(second[0..<15]) == expectedSecond)
        #expect(first[15...].allSatisfy { $0 == 0 })
        #expect(second[15...].allSatisfy { $0 == 0 })

        // The follow-up differs from the first report only at bytes 1, 3, 4 and 6.
        let differences = zip(first, second).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        #expect(differences == [1, 3, 4, 6])
    }

    @Test("USB bridge report for set 0xD7 = 1 carries the matching DDC packet")
    func usbBridgeReportsPBPOff() {
        let (first, _) = DDCPacket.usbBridgeReports(set: 0xD7, value: 1)
        #expect(Array(first[8..<15]) == [0x51, 0x84, 0x03, 0xD7, 0x00, 0x01, 0x6E])
        #expect(first[4] == 7)
    }
}

@Suite("VCPWrite")
struct VCPWriteTests {
    @Test("fields round-trip and encode to the design vector")
    func roundTrip() {
        let write = VCPWrite(code: 0xD7, value: 1, source: .standard)
        #expect(write.code == 0xD7)
        #expect(write.value == 1)
        #expect(write.source == .standard)
        #expect(write == VCPWrite(code: 0xD7, value: 1))
        #expect(write != VCPWrite(code: 0xD7, value: 1, source: .lgSideChannel))
        #expect(DDCPacket.vcpSet(write) == [0x84, 0x03, 0xD7, 0x00, 0x01, 0x6E])
        #expect(DDCPacket.vcpSet(VCPWrite(code: 0xD7, value: 1, source: .lgSideChannel)) == [0x84, 0x03, 0xD7, 0x00, 0x01, 0x6F])
        #expect(write.description == "VCPWrite(0xD7 = 1, source 0x51)")
    }

    @Test("DDCSource raw values")
    func sources() {
        #expect(DDCSource.standard.rawValue == 0x51)
        #expect(DDCSource.lgSideChannel.rawValue == 0x50)
    }
}
