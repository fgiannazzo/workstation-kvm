import DDCKit
import Devices
import Foundation
import SwitchboardCore
import Testing

/// Records every requested sleep and returns immediately.
actor SleepRecorder {
    private(set) var durations: [Duration] = []
    func record(_ duration: Duration) { durations.append(duration) }
}

func recordingSleeper(_ recorder: SleepRecorder) -> Sleeper {
    { duration in await recorder.record(duration) }
}

/// A transport whose writes fail, to prove write errors propagate.
actor FailingTransport: DDCTransport {
    nonisolated let name = "failing"
    let error: DDCError
    init(error: DDCError) { self.error = error }
    func write(_ write: VCPWrite) async throws { throw error }
    func read(code: UInt8) async throws -> VCPReply { throw DDCError.noReply }
}

// MARK: - Whitelist

@Suite("LGDualUpCommand whitelist")
struct LGDualUpCommandTests {
    @Test("exactly two commands exist")
    func exactlyTwo() {
        #expect(LGDualUpCommand.allCases == [.pbpOn, .pbpOff])
        #expect(LGDualUpCommand.allCases.count == 2)
    }

    @Test("pbpOn: 0xD7 = 0 over the USB bridge, expects 0 back")
    func pbpOn() {
        let command = LGDualUpCommand.pbpOn
        #expect(command.code == 0xD7)
        #expect(command.value == 0)
        #expect(command.transport == .usbBridge)
        #expect(command.expectedReadBack == 0)
        #expect(command.targetState == .on)
        #expect(command.write == VCPWrite(code: 0xD7, value: 0, source: .standard))
    }

    @Test("pbpOff: 0xD7 = 1 over the video cable, expects 1 back")
    func pbpOff() {
        let command = LGDualUpCommand.pbpOff
        #expect(command.code == 0xD7)
        #expect(command.value == 1)
        #expect(command.transport == .videoCable)
        #expect(command.expectedReadBack == 1)
        #expect(command.targetState == .off)
        #expect(command.write == VCPWrite(code: 0xD7, value: 1, source: .standard))
    }

    @Test("every command writes 0xD7 on source 0x51; never 0xF4, never 0x60, never 0x50")
    func invariants() {
        for command in LGDualUpCommand.allCases {
            #expect(command.write.source == .standard)
            #expect(command.write.code == DualUpCode.pbp)
            #expect(command.write.code != 0xF4)
            #expect(command.write.code != 0x60)
            #expect(command.write.value == command.expectedReadBack)
            #expect(command.write.value <= 1)
        }
    }

    @Test("commands and transports encode as their raw strings")
    func codable() throws {
        #expect(String(decoding: try JSONEncoder().encode([LGDualUpCommand.pbpOn, .pbpOff]), as: UTF8.self) == #"["pbpOn","pbpOff"]"#)
        #expect(try JSONDecoder().decode(LGDualUpCommand.self, from: Data(#""pbpOff""#.utf8)) == .pbpOff)
        #expect(LGDualUpTransport.allCases.map(\.rawValue) == ["usbBridge", "videoCable"])
    }
}

// MARK: - perform

@Suite("LGDualUp.perform")
struct LGDualUpPerformTests {
    struct Rig {
        let cable: FakeDDC
        let usb: FakeDDC
        let sleeps: SleepRecorder
        let dualUp: LGDualUp

        init(cableReads: [UInt8: [UInt16?]]) {
            cable = FakeDDC(name: "video cable (SDQHD)", reads: cableReads)
            usb = FakeDDC(name: "USB bridge (SDQHD)", supportsRead: false)
            sleeps = SleepRecorder()
            dualUp = LGDualUp(videoCable: cable, usbBridge: usb, sleep: recordingSleeper(sleeps))
        }
    }

    @Test("pbpOn writes 0xD7 = 0 on the USB bridge only, settles, reads 0xD7 back over the cable, verified on 0")
    func pbpOnVerified() async throws {
        let rig = Rig(cableReads: [0xD7: [0], 0xF5: [1]])

        let outcome = try await rig.dualUp.perform(.pbpOn)

        #expect(await rig.usb.writes == [VCPWrite(code: 0xD7, value: 0, source: .standard)])
        #expect(await rig.cable.writes.isEmpty)
        #expect(await rig.usb.readRequests.isEmpty, "the bridge is never read")
        #expect(await rig.cable.readCount(code: 0xD7) == 2, "double dump")
        let sleeps = await rig.sleeps.durations
        #expect(sleeps.first == Timing.settleAfterModeChange)
        #expect(sleeps.contains(Timing.betweenDumps))

        #expect(outcome.command == .pbpOn)
        #expect(outcome.transport == "USB bridge (SDQHD)")
        #expect(outcome.expected == 0)
        #expect(outcome.observed == 0)
        #expect(outcome.verified)
        #expect(outcome.reading.pbp == .on)
        #expect(outcome.reading.mainInput == .hdmi1)
        #expect(outcome.reading.raw == [0xD7: 0, 0xF5: 1])
    }

    @Test("pbpOn is unverified when the cable still reads 1; it does not throw")
    func pbpOnUnverified() async throws {
        let rig = Rig(cableReads: [0xD7: [1], 0xF5: [1]])
        let outcome = try await rig.dualUp.perform(.pbpOn)
        #expect(await rig.usb.writes.count == 1)
        #expect(outcome.observed == 1)
        #expect(!outcome.verified)
        #expect(outcome.reading.pbp == .off)
    }

    @Test("pbpOn with an unreadable 0xD7 is unverified with observed nil, not an error")
    func pbpOnUnreadable() async throws {
        let rig = Rig(cableReads: [0xF5: [1]])   // 0xD7 never answers
        let outcome = try await rig.dualUp.perform(.pbpOn)
        #expect(outcome.observed == nil)
        #expect(!outcome.verified)
        #expect(outcome.reading.pbp == .unknown)
        #expect(outcome.reading.raw == [0xF5: 1])
    }

    @Test("a flapping 0xD7 is unverified with observed nil")
    func pbpOnFlapping() async throws {
        let rig = Rig(cableReads: [0xD7: [0, 1, 0, 1, 0, 1, 0, 1, 0], 0xF5: [1]])
        let outcome = try await rig.dualUp.perform(.pbpOn)
        #expect(outcome.observed == nil)
        #expect(!outcome.verified)
    }

    @Test("pbpOff writes 0xD7 = 1 on the video cable only and is verified on 1")
    func pbpOffVerified() async throws {
        let rig = Rig(cableReads: [0xD7: [1], 0xF5: [1]])

        let outcome = try await rig.dualUp.perform(.pbpOff)

        #expect(await rig.cable.writes == [VCPWrite(code: 0xD7, value: 1, source: .standard)])
        #expect(await rig.usb.writes.isEmpty)
        #expect(await rig.cable.readCount(code: 0xD7) == 2)
        #expect(await rig.sleeps.durations.first == Timing.settleAfterModeChange)
        #expect(outcome.command == .pbpOff)
        #expect(outcome.transport == "video cable (SDQHD)")
        #expect(outcome.expected == 1)
        #expect(outcome.observed == 1)
        #expect(outcome.verified)
        #expect(outcome.reading.pbp == .off)
    }

    @Test("pbpOff is unverified when the cable reads 0, and when 0xD7 is unreadable")
    func pbpOffUnverified() async throws {
        let still = try await Rig(cableReads: [0xD7: [0], 0xF5: [1]]).dualUp.perform(.pbpOff)
        #expect(still.observed == 0)
        #expect(!still.verified)

        let unreadable = try await Rig(cableReads: [:]).dualUp.perform(.pbpOff)
        #expect(unreadable.observed == nil)
        #expect(!unreadable.verified)
        #expect(unreadable.reading.raw.isEmpty)
    }

    @Test("a write error propagates: no settle, no read-back")
    func writeErrorPropagates() async {
        let cable = FakeDDC(reads: [0xD7: [1]])
        let failing = FailingTransport(error: .ioKit(-536_870_206, operation: "IOHIDDeviceSetReport(first report)"))
        let sleeps = SleepRecorder()
        let dualUp = LGDualUp(videoCable: cable, usbBridge: failing, sleep: recordingSleeper(sleeps))

        await #expect(throws: DDCError.ioKit(-536_870_206, operation: "IOHIDDeviceSetReport(first report)")) {
            try await dualUp.perform(.pbpOn)
        }
        #expect(await sleeps.durations.isEmpty)
        #expect(await cable.readRequests.isEmpty)
        #expect(await cable.writes.isEmpty)
    }

    @Test("a video-cable write error propagates too (display not found)")
    func cableWriteErrorPropagates() async {
        let failing = FailingTransport(error: .displayNotFound("SDQHD"))
        let dualUp = LGDualUp(videoCable: failing, usbBridge: FakeDDC(supportsRead: false), sleep: { _ in })
        await #expect(throws: DDCError.displayNotFound("SDQHD")) { try await dualUp.perform(.pbpOff) }
    }

    @Test("built without a bridge, pbpOn throws bridgeNotFound and the cable is untouched; pbpOff still works")
    func defaultBridgeIsUnavailable() async throws {
        let cable = FakeDDC(reads: [0xD7: [1], 0xF5: [1]])
        let dualUp = LGDualUp(videoCable: cable, sleep: { _ in })

        let error = await thrownDDCError { _ = try await dualUp.perform(.pbpOn) }
        guard case .bridgeNotFound? = error else { Issue.record("expected bridgeNotFound, got \(String(describing: error))"); return }
        #expect(await cable.writes.isEmpty)
        #expect(await cable.readRequests.isEmpty)
        #expect(dualUp.usbBridge.name.contains("not configured"))

        let outcome = try await dualUp.perform(.pbpOff)
        #expect(outcome.verified)
        #expect(await cable.writes == [VCPWrite(code: 0xD7, value: 1)])
    }

    @Test("readState still never writes, on either transport")
    func readStateNeverWrites() async {
        let rig = Rig(cableReads: [0xD7: [1], 0xF5: [1]])
        _ = await rig.dualUp.readState()
        #expect(await rig.cable.writes.isEmpty)
        #expect(await rig.usb.writes.isEmpty)
    }

    func thrownDDCError(_ body: () async throws -> Void) async -> DDCError? {
        do {
            try await body()
            return nil
        } catch let error as DDCError {
            return error
        } catch {
            return nil
        }
    }
}

// MARK: - JSON

@Suite("WriteOutcome and DualUpReading JSON")
struct WriteOutcomeJSONTests {
    static func tree(_ value: some Encodable) throws -> NSDictionary {
        let data = try JSONEncoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    @Test("WriteOutcome round-trips; raw is an object keyed by hex code; observed nil is null")
    func roundTrip() throws {
        let verified = WriteOutcome(command: .pbpOn, transport: "USB bridge (SDQHD)", expected: 0, observed: 0, verified: true, reading: DualUpReading(raw: [0xD7: 0, 0xF5: 1]))
        let encoded = try JSONEncoder().encode(verified)
        #expect(try JSONDecoder().decode(WriteOutcome.self, from: encoded) == verified)

        let tree = try Self.tree(verified)
        #expect(tree["command"] as? String == "pbpOn")
        #expect(tree["transport"] as? String == "USB bridge (SDQHD)")
        #expect(tree["expected"] as? Int == 0)
        #expect(tree["observed"] as? Int == 0)
        #expect(tree["verified"] as? Bool == true)
        let reading = try #require(tree["reading"] as? NSDictionary)
        #expect(reading["pbp"] as? String == "on")
        #expect(reading["mainInput"] as? String == "hdmi1")
        #expect(reading["raw"] as? NSDictionary == ["0xD7": 0, "0xF5": 1])

        let unverified = WriteOutcome(command: .pbpOff, transport: "video cable (SDQHD)", expected: 1, observed: nil, verified: false, reading: DualUpReading(raw: [:]))
        let unverifiedTree = try Self.tree(unverified)
        #expect(unverifiedTree["observed"] is NSNull)
        #expect(try JSONDecoder().decode(WriteOutcome.self, from: try JSONEncoder().encode(unverified)) == unverified)
    }

    @Test("DualUpReading re-derives pbp and mainInput from raw on decode")
    func readingDerivesFromRaw() throws {
        let json = #"{"pbp": "unknown", "mainInput": "unknown", "raw": {"0xd7": 1, "0xF5": 2}}"#
        let reading = try JSONDecoder().decode(DualUpReading.self, from: Data(json.utf8))
        #expect(reading.raw == [0xD7: 1, 0xF5: 2])
        #expect(reading.pbp == .off)
        #expect(reading.mainInput == .hdmi2)
        #expect(DualUpReading.key(for: 0xD7) == "0xD7")
    }

    @Test("a raw key that is not a VCP code fails to decode")
    func badRawKey() {
        let json = #"{"pbp": "off", "mainInput": "hdmi1", "raw": {"pbp": 1}}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(DualUpReading.self, from: Data(json.utf8)) }
    }
}

// MARK: - Dry run

@Suite("DryRunFormatter")
struct DryRunFormatterTests {
    static let zeroPadding = String(repeating: " 00", count: 49)

    @Test("pbpOn prints both 64-byte USB reports exactly as docs/DESIGN.md writes them")
    func pbpOn() {
        let lines = DryRunFormatter.lines(for: .pbpOn, displayNameContains: "SDQHD")
        let text = lines.joined(separator: "\n")

        #expect(lines.contains("report 1: 08 01 55 03 07 00 03 37 51 84 03 D7 00 00 6F" + Self.zeroPadding))
        #expect(lines.contains("report 2: 08 02 55 04 0B 00 0B 37 51 84 03 D7 00 00 6F" + Self.zeroPadding))
        #expect(lines.contains("write: VCP 0xD7 = 0, source 0x51"))
        #expect(text.contains("USB bridge"))
        #expect(text.contains("report id 8, 64 bytes"))
        #expect(text.contains("SDQHD"))
        #expect(text.contains("read 0xD7 twice over the video cable"))
        #expect(text.contains("both read 0 (on)"))
        #expect(lines.first?.hasPrefix("dry run: pbpOn") == true)
        // Each report line is "report N: " plus 64 two-digit bytes separated by spaces.
        for line in lines where line.hasPrefix("report ") {
            let bytes = line.split(separator: ": ", maxSplits: 1)[1].split(separator: " ")
            #expect(bytes.count == 64)
        }
    }

    @Test("pbpOff prints the 6-byte DDC packet on source 0x51")
    func pbpOff() {
        let lines = DryRunFormatter.lines(for: .pbpOff, displayNameContains: "SDQHD")
        let text = lines.joined(separator: "\n")

        #expect(lines.contains("packet: 84 03 D7 00 01 6E"))
        #expect(lines.contains("write: VCP 0xD7 = 1, source 0x51"))
        #expect(text.contains("video cable"))
        #expect(text.contains("chip 0x37, source 0x51, 6 bytes"))
        #expect(text.contains("both read 1 (off)"))
        #expect(!text.contains("report 1"))
    }

    @Test("neither dry run ever mentions source 0x50 or code 0xF4")
    func neverSideChannel() {
        for command in LGDualUpCommand.allCases {
            let text = DryRunFormatter.lines(for: command, displayNameContains: "SDQHD").joined(separator: "\n")
            #expect(!text.contains("0x50"))
            #expect(!text.contains("0xF4"))
        }
    }
}
