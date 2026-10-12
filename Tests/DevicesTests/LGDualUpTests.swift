import DDCKit
import Devices
import SwitchboardCore
import Testing

private let instant: Sleeper = { _ in }

@Suite("DualUpReading mapping")
struct DualUpReadingTests {
    @Test("0xD7: 0 = on, 1 = off, other or missing = unknown", arguments: [
        (UInt16?.some(0), PBPState.on),
        (UInt16?.some(1), PBPState.off),
        (UInt16?.some(2), PBPState.unknown),
        (UInt16?.some(0xFF), PBPState.unknown),
        (UInt16?.none, PBPState.unknown),
    ])
    func pbp(value: UInt16?, expected: PBPState) {
        #expect(DualUpReading.pbpState(from: value) == expected)
        var raw: [UInt8: UInt16] = [:]
        if let value { raw[DualUpCode.pbp] = value }
        #expect(DualUpReading(raw: raw).pbp == expected)
    }

    @Test("0xF5: 1 = HDMI 1, 2 = HDMI 2, other or missing = unknown", arguments: [
        (UInt16?.some(1), MainInput.hdmi1),
        (UInt16?.some(2), MainInput.hdmi2),
        (UInt16?.some(0), MainInput.unknown),
        (UInt16?.some(3), MainInput.unknown),
        (UInt16?.some(4), MainInput.unknown),
        (UInt16?.none, MainInput.unknown),
    ])
    func mainInput(value: UInt16?, expected: MainInput) {
        #expect(DualUpReading.mainInput(from: value) == expected)
        var raw: [UInt8: UInt16] = [:]
        if let value { raw[DualUpCode.mainInput] = value }
        #expect(DualUpReading(raw: raw).mainInput == expected)
    }

    @Test("codes are the verified ones")
    func codes() {
        #expect(DualUpCode.pbp == 0xD7)
        #expect(DualUpCode.mainInput == 0xF5)
        #expect(DualUpCode.stateCodes == [0xD7, 0xF5])
    }
}

@Suite("LGDualUp.readState")
struct LGDualUpReadStateTests {
    @Test("PBP off on HDMI 1 (the hardware checklist's expected state)")
    func pbpOffHDMI1() async {
        let cable = FakeDDC(name: "video cable", reads: [0xD7: [1], 0xF5: [1]])
        let dualUp = LGDualUp(videoCable: cable, sleep: instant)

        let reading = await dualUp.readState()

        #expect(reading.pbp == .off)
        #expect(reading.mainInput == .hdmi1)
        #expect(reading.raw == [0xD7: 1, 0xF5: 1])
    }

    @Test("PBP on, main input swapped to HDMI 2")
    func pbpOnHDMI2() async {
        let cable = FakeDDC(reads: [0xD7: [0], 0xF5: [2]])
        let reading = await LGDualUp(videoCable: cable, sleep: instant).readState()
        #expect(reading.pbp == .on)
        #expect(reading.mainInput == .hdmi2)
    }

    @Test("an unreadable code is unknown and absent from raw")
    func unreadable() async {
        let cable = FakeDDC(reads: [0xD7: [1]])   // 0xF5 never answers
        let reading = await LGDualUp(videoCable: cable, sleep: instant).readState()
        #expect(reading.pbp == .off)
        #expect(reading.mainInput == .unknown)
        #expect(reading.raw == [0xD7: 1])
    }

    @Test("nothing readable is all unknown, never defaulted")
    func nothingReadable() async {
        let cable = FakeDDC()
        let reading = await LGDualUp(videoCable: cable, sleep: instant).readState()
        #expect(reading.pbp == .unknown)
        #expect(reading.mainInput == .unknown)
        #expect(reading.raw.isEmpty)
    }

    @Test("a flapping code is unknown; a stable one is kept")
    func flapping() async {
        let cable = FakeDDC(reads: [0xD7: [0, 1, 0, 1, 0, 1, 0, 1, 0], 0xF5: [1]])
        let reading = await LGDualUp(videoCable: cable, sleep: instant).readState()
        #expect(reading.pbp == .unknown)
        #expect(reading.mainInput == .hdmi1)
    }

    @Test("a code that settles after a retry is reported")
    func settles() async {
        let cable = FakeDDC(reads: [0xD7: [nil, nil, 1], 0xF5: [1]])
        let reading = await LGDualUp(videoCable: cable, sleep: instant).readState()
        #expect(reading.pbp == .off)
        #expect(reading.mainInput == .hdmi1)
    }

    @Test("readState never writes")
    func neverWrites() async {
        let cable = FakeDDC(reads: [0xD7: [1], 0xF5: [1]])
        _ = await LGDualUp(videoCable: cable, sleep: instant).readState()
        #expect(await cable.writes.isEmpty)
    }
}
