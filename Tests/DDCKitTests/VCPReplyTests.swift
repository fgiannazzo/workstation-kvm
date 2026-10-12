import DDCKit
import Testing

@Suite("VCPReply decoding")
struct VCPReplyTests {
    /// A good reply for 0xD7: rc 0, max 0x0001, current 0x0001.
    static let good: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0xD7, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00]

    @Test("good 12-byte reply")
    func good() throws {
        let reply = try VCPReply(bytes: Self.good)
        #expect(reply.resultCode == 0)
        #expect(reply.code == 0xD7)
        #expect(reply.maximum == 1)
        #expect(reply.current == 1)
        #expect(reply.isOK)
        #expect(reply == VCPReply(resultCode: 0, code: 0xD7, maximum: 1, current: 1))
    }

    @Test("16-bit max and current are big-endian")
    func wideValues() throws {
        var bytes = Self.good
        bytes[4] = 0xF5
        bytes[6] = 0x12; bytes[7] = 0x34
        bytes[8] = 0xAB; bytes[9] = 0xCD
        let reply = try VCPReply(bytes: bytes)
        #expect(reply.code == 0xF5)
        #expect(reply.maximum == 0x1234)
        #expect(reply.current == 0xABCD)
    }

    @Test("byte 2 must be 0x02")
    func wrongOpcode() {
        var bytes = Self.good
        bytes[2] = 0x00
        #expect(throws: DDCError.invalidReply(bytes)) { try VCPReply(bytes: bytes) }
    }

    @Test("a non-zero result code is preserved, not thrown")
    func nonZeroResultCode() throws {
        var bytes = Self.good
        bytes[3] = 0x01
        let reply = try VCPReply(bytes: bytes)
        #expect(reply.resultCode == 1)
        #expect(!reply.isOK)
        #expect(reply.code == 0xD7)
    }

    @Test("a short buffer is invalid")
    func shortBuffer() {
        let short = Array(Self.good[0..<8])
        #expect(throws: DDCError.invalidReply(short)) { try VCPReply(bytes: short) }
        #expect(throws: DDCError.invalidReply([])) { try VCPReply(bytes: []) }
    }

    @Test("DDCError descriptions name the failure")
    func errorDescriptions() {
        #expect(DDCError.displayNotFound("SDQHD").description.contains("SDQHD"))
        #expect(DDCError.ioKit(-536870206, operation: "IOAVServiceReadI2C").description.contains("IOAVServiceReadI2C"))
        #expect(DDCError.invalidReply([0x6E, 0x80]).description.contains("6E 80"))
        #expect(DDCError.readUnsupported.description.contains("cannot read"))
        #expect(DDCError.noReply.description.contains("no reply"))
    }
}
