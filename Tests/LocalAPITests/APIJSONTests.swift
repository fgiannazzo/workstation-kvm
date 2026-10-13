import Actions
import DDCKit
import Devices
import ESP32Kit
import Foundation
import LocalAPI
import StateStore
import SwitchboardCore
import Testing

@Suite("APIJSON dates")
struct APIJSONTests {
    @Test("dates format as ISO 8601 with three fractional digits and a Z")
    func formats() {
        #expect(APIJSON.string(from: Date(timeIntervalSince1970: 1_791_749_703.12)) == "2026-10-11T20:15:03.120Z")
        #expect(APIJSON.string(from: Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00.000Z")
        #expect(APIJSON.string(from: Date(timeIntervalSince1970: 951_868_799.999)) == "2000-02-29T23:59:59.999Z")
        #expect(APIJSON.string(from: Date(timeIntervalSince1970: -1)) == "1969-12-31T23:59:59.000Z")
        #expect(APIJSON.string(from: Date(timeIntervalSince1970: -0.001)) == "1969-12-31T23:59:59.999Z")
        #expect(APIJSON.string(from: Date(timeIntervalSince1970: 1_791_749_703.9996)) == "2026-10-11T20:15:04.000Z", "rounds to the millisecond")
        #expect(APIJSON.string(from: .distantPast) == "0001-01-01T00:00:00.000Z", "a state that was never updated")
        #expect(APIJSON.string(from: .distantPast) == APIJSON.neverUpdated)
        #expect(APIJSON.string(from: Date(timeIntervalSince1970: 4_102_444_800)) == "2100-01-01T00:00:00.000Z")
    }

    @Test("a fraction that has no exact binary form still prints the digits it was written with")
    func exactDigits() {
        // ISO8601DateFormatter prints some of these one millisecond short.
        for millisecond in 0..<1000 {
            let seconds = 1_791_749_703.0 + Double(millisecond) / 1000
            let text = APIJSON.string(from: Date(timeIntervalSince1970: seconds))
            let expected = "2026-10-11T20:15:03." + String(repeating: "0", count: 3 - String(millisecond).count) + String(millisecond) + "Z"
            #expect(text == expected)
        }
    }

    @Test("parsing accepts the written form, no fraction, any number of digits, and numeric offsets")
    func parses() {
        #expect(APIJSON.date(from: "2026-10-11T20:15:03.120Z") == Date(timeIntervalSince1970: 1_791_749_703.12))
        #expect(APIJSON.date(from: "2026-10-11T20:15:03Z") == Date(timeIntervalSince1970: 1_791_749_703))
        #expect(APIJSON.date(from: "2026-10-11T20:15:03.1Z") == Date(timeIntervalSince1970: 1_791_749_703.1))
        #expect(APIJSON.date(from: "2026-10-11T20:15:03.123456Z") == Date(timeIntervalSince1970: 1_791_749_703.123456))
        #expect(APIJSON.date(from: "2026-10-11t20:15:03z") == Date(timeIntervalSince1970: 1_791_749_703))
        #expect(APIJSON.date(from: "2026-10-11T22:15:03+02:00") == Date(timeIntervalSince1970: 1_791_749_703))
        #expect(APIJSON.date(from: "2026-10-11T15:45:03-04:30") == Date(timeIntervalSince1970: 1_791_749_703))
        #expect(APIJSON.date(from: "2026-10-11T22:15:03+0200") == Date(timeIntervalSince1970: 1_791_749_703))
        #expect(APIJSON.date(from: "1970-01-01T00:00:00.000Z") == Date(timeIntervalSince1970: 0))
        #expect(APIJSON.date(from: "0001-01-01T00:00:00.000Z") == Date.distantPast)
    }

    @Test("parsing refuses what is not a date")
    func refuses() {
        for text in [
            "", "now", "2026-10-11", "2026-10-11T20:15:03", "2026-10-11 20:15:03Z", "2026-13-11T20:15:03Z",
            "2026-10-00T20:15:03Z", "2026-10-11T24:15:03Z", "2026-10-11T20:60:03Z", "2026-10-11T20:15:03.Z",
            "2026-10-11T20:15:03.12", "2026-10-11T20:15:03Z extra", "2026-10-11T20:15:03+2", "26-10-11T20:15:03Z", "1791749703",
        ] {
            #expect(APIJSON.date(from: text) == nil, "\"\(text)\"")
        }
    }

    @Test("format and parse are inverses at millisecond precision, before and after 1970")
    func roundTrip() {
        for seconds in [0.0, 1.5, 86_399.999, 1_791_749_703.12, 951_868_799.001, -1.25, -86_400.5, -62_000_000_000.0, 253_402_300_799.0] {
            let date = Date(timeIntervalSince1970: seconds)
            let text = APIJSON.string(from: date)
            let back = APIJSON.date(from: text)
            #expect(back != nil, Comment(rawValue: text))
            if let back { #expect(abs(back.timeIntervalSince(date)) < 0.0005, "\(text) vs \(seconds)") }
        }
    }

    @Test("the encoder writes a state's date as that string, with sorted keys and no spaces")
    func encodesState() throws {
        var state = SwitchboardState()
        state.pbp = .on
        state.updatedAt = Date(timeIntervalSince1970: 1_791_749_703.12)
        let text = String(decoding: try APIJSON.makeEncoder().encode(state), as: UTF8.self)
        #expect(text == #"{"controllerReachable":false,"displays":"unknown","dualUpReachable":false,"hdmiInput":{},"lastError":null,"mainInput":"unknown","pbp":"on","updatedAt":"2026-10-11T20:15:03.120Z","usbPort":null}"#)

        let back = try APIJSON.makeDecoder().decode(SwitchboardState.self, from: Data(text.utf8))
        #expect(back == state)
    }

    @Test("the decoder reports a bad date with the text that was wrong")
    func decodeError() {
        let json = Data(#"{"updatedAt":"yesterday"}"#.utf8)
        do {
            _ = try APIJSON.makeDecoder().decode(SwitchboardState.self, from: json)
            Issue.record("expected an error")
        } catch {
            #expect("\(error)".contains("yesterday"))
        }
    }

    @Test("slashes are not escaped")
    func slashes() throws {
        let text = String(decoding: try APIJSON.makeEncoder().encode(["url": "a/b"]), as: UTF8.self)
        #expect(text == #"{"url":"a/b"}"#)
    }
}

@Suite("Run failure kinds")
struct RunFailureTests {
    private func failed(_ message: String) -> RunEvent {
        RunEvent(runId: "r", id: "x", kind: .action, status: .failed, step: 1, stepCount: 1, message: message)
    }

    @Test("only a failed event has a failure kind")
    func onlyFailed() {
        for status in [RunEvent.Status.started, .step, .finished] {
            let event = RunEvent(runId: "r", id: "x", kind: .action, status: status, step: 0, stepCount: 1, message: "unverified: 0xD7")
            #expect(event.failureKind == nil)
        }
    }

    @Test("an unverified write, built from the real ActionError, is recognised")
    func unverified() {
        let outcome = WriteOutcome(
            command: .pbpOn, transport: "USB bridge", expected: 0, observed: 1, verified: false,
            reading: DualUpReading(raw: [0xD7: 1, 0xF5: 1])
        )
        let unreadable = WriteOutcome(
            command: .pbpOff, transport: "video cable", expected: 1, observed: nil, verified: false,
            reading: DualUpReading(raw: [:])
        )
        let cases: [(String, WriteOutcome)] = [("monitor.pbp.on", outcome), ("monitor.pbp.off", unreadable)]
        for (action, outcome) in cases {
            #expect(failed("\(action): \(ActionError.unverified(outcome))").failureKind == .unverifiedWrite)
        }
    }

    @Test("controller trouble, built from the real errors, is recognised")
    func controller() {
        let url = URL(string: "http://192.168.1.50:80")!
        let errors: [ActionError] = [
            .controllerNotConfigured,
            .controller(.unreachable(url, underlying: "connection refused")),
            .controller(.timeout),
        ]
        for error in errors {
            #expect(failed("usb.select: \(error)").failureKind == .controllerUnreachable, "\(error)")
        }
    }

    @Test("everything else is other")
    func other() {
        let url = URL(string: "http://192.168.1.50:80")!
        let errors: [ActionError] = [
            .controller(.httpStatus(400, body: "{}")),
            .controller(.invalidResponse("x")),
            .verifyFailed(["usbPort: expected 2, got 1"]),
            .monitorUnavailable("display not found"),
            .cancelled,
            .invalidParameter("port", "9 is out of range"),
        ]
        for error in errors {
            #expect(failed("x: \(error)").failureKind == .other, "\(error)")
        }
        _ = url
    }
}
