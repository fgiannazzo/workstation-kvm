import Foundation
import SwitchboardCore
import Testing

/// Parses JSON into a comparable tree so two documents can be compared structurally.
private func jsonObject(_ data: Data) throws -> NSDictionary {
    let object = try JSONSerialization.jsonObject(with: data)
    return try #require(object as? NSDictionary)
}

@Suite("ControllerState")
struct ControllerStateTests {
    /// The exact `GET /state` document from docs/BRIEF.md, section 5.
    static let briefJSON = #"{ "hdmi": { "dualup": 1, "lg4k": 1, "samsung": 1 }, "usb": { "port": 1, "source": "aten" }, "uptime": 123 }"#

    @Test("the brief's GET /state JSON decodes and re-encodes equal")
    func briefRoundTrip() throws {
        let data = Data(Self.briefJSON.utf8)
        let state = try JSONDecoder().decode(ControllerState.self, from: data)

        #expect(state.hdmi == [.dualup: 1, .lg4k: 1, .samsung: 1])
        #expect(state.usb == ControllerState.USB(port: 1, source: "aten"))
        #expect(state.uptime == 123)

        let encoded = try JSONEncoder().encode(state)
        #expect(try jsonObject(encoded) == jsonObject(data))

        let again = try JSONDecoder().decode(ControllerState.self, from: encoded)
        #expect(again == state)
    }

    @Test("hdmi encodes as an object keyed by display id, not an array")
    func hdmiIsObject() throws {
        let state = ControllerState(hdmi: [.lg4k: 2], usb: .init(port: 3, source: "aten"), uptime: 1)
        let tree = try jsonObject(try JSONEncoder().encode(state))
        let hdmi = try #require(tree["hdmi"] as? NSDictionary)
        #expect(hdmi == ["lg4k": 2])
    }

    @Test("partial hdmi objects and unknown display keys decode")
    func partialAndUnknownKeys() throws {
        let json = #"{ "hdmi": { "lg4k": 2, "projector": 1 }, "usb": { "port": 4, "source": "aten" }, "uptime": 0 }"#
        let state = try JSONDecoder().decode(ControllerState.self, from: Data(json.utf8))
        #expect(state.hdmi == [.lg4k: 2])
    }
}

@Suite("SwitchboardState")
struct SwitchboardStateTests {
    @Test("defaults are unknown / nil / empty / false / distantPast")
    func defaults() {
        let state = SwitchboardState()
        #expect(state.pbp == .unknown)
        #expect(state.mainInput == .unknown)
        #expect(state.usbPort == nil)
        #expect(state.hdmiInput.isEmpty)
        #expect(state.controllerReachable == false)
        #expect(state.dualUpReachable == false)
        #expect(state.lastError == nil)
        #expect(state.updatedAt == .distantPast)
    }

    @Test("hdmiInput encodes as an object, not an array")
    func hdmiInputIsObject() throws {
        let state = SwitchboardState(hdmiInput: [.dualup: 1, .samsung: 2])
        let tree = try jsonObject(try JSONEncoder().encode(state))
        let hdmi = try #require(tree["hdmiInput"] as? NSDictionary)
        #expect(hdmi == ["dualup": 1, "samsung": 2])
        #expect(tree["usbPort"] is NSNull)
        #expect(tree["lastError"] is NSNull)
    }

    @Test("the docs/API.md example decodes and round-trips")
    func apiExampleRoundTrip() throws {
        let json = """
            {
              "pbp": "on",
              "mainInput": "hdmi1",
              "usbPort": 2,
              "hdmiInput": { "dualup": 1, "lg4k": 2, "samsung": 1 },
              "controllerReachable": true,
              "dualUpReachable": true,
              "lastError": null,
              "updatedAt": "2026-10-11T20:15:03.120Z"
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        let state = try decoder.decode(SwitchboardState.self, from: Data(json.utf8))
        #expect(state.pbp == .on)
        #expect(state.mainInput == .hdmi1)
        #expect(state.usbPort == 2)
        #expect(state.hdmiInput == [.dualup: 1, .lg4k: 2, .samsung: 1])
        #expect(state.controllerReachable)
        #expect(state.dualUpReachable)
        #expect(state.lastError == nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601WithFractionalSeconds
        let again = try decoder.decode(SwitchboardState.self, from: try encoder.encode(state))
        #expect(again == state)
    }

    @Test("enum raw values are the lower-case strings from the API contract")
    func enumRawValues() {
        #expect(PBPState.on.rawValue == "on")
        #expect(PBPState.off.rawValue == "off")
        #expect(PBPState.unknown.rawValue == "unknown")
        #expect(MainInput.hdmi1.rawValue == "hdmi1")
        #expect(MainInput.hdmi2.rawValue == "hdmi2")
        #expect(DisplayID.allCases.map(\.rawValue) == ["dualup", "lg4k", "samsung"])
    }
}

@Suite("LogEntry")
struct LogEntryTests {
    @Test("levels order debug < info < warning < error and round-trip through JSON")
    func levels() throws {
        #expect(LogEntry.Level.debug < .info)
        #expect(LogEntry.Level.info < .warning)
        #expect(LogEntry.Level.warning < .error)

        let entry = LogEntry(level: .warning, message: "link re-training")
        let data = try JSONEncoder().encode(entry)
        let again = try JSONDecoder().decode(LogEntry.self, from: data)
        #expect(again.id == entry.id)
        #expect(again.level == .warning)
        #expect(again.message == "link re-training")
    }
}

extension JSONDecoder.DateDecodingStrategy {
    static var iso8601WithFractionalSeconds: Self {
        .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(string)"))
            }
            return date
        }
    }
}

extension JSONEncoder.DateEncodingStrategy {
    static var iso8601WithFractionalSeconds: Self {
        .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
    }
}
