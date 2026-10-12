import Actions
import Foundation
import SwitchboardCore

// The text `switchboardctl state` and `switchboardctl events` print. It lives here, next to
// `RunEvent.line` and `Macro.summary`, so it is unit-tested; the CLI only decides where to print it.

extension SwitchboardState {
    /// The lines of `switchboardctl state`:
    ///
    ///     pbp: on
    ///     main input: HDMI 1
    ///     usb: port 2
    ///     hdmi: dualup 1  lg4k 2  samsung 1
    ///     controller: reachable
    ///     monitor: reachable
    ///     last error: none
    ///     updated: 2026-10-11T20:15:03.120Z
    ///
    /// Anything unknown reads `unknown`, never a default.
    public var summaryLines: [String] {
        let pbpText: String
        switch pbp {
        case .on: pbpText = "on"
        case .off: pbpText = "off"
        case .unknown: pbpText = "unknown"
        }
        let inputText: String
        switch mainInput {
        case .hdmi1: inputText = "HDMI 1"
        case .hdmi2: inputText = "HDMI 2"
        case .unknown: inputText = "unknown"
        }
        let hdmi = DisplayID.allCases.map { "\($0.rawValue) \(hdmiInput[$0].map(String.init) ?? "unknown")" }
        return [
            "pbp: \(pbpText)",
            "main input: \(inputText)",
            "usb: " + (usbPort.map { "port \($0)" } ?? "unknown"),
            "hdmi: " + hdmi.joined(separator: "  "),
            "controller: \(controllerReachable ? "reachable" : "not reachable")",
            "monitor: \(dualUpReachable ? "reachable" : "not reachable")",
            "last error: \(lastError ?? "none")",
            "updated: \(updatedAt <= .distantPast ? "never" : APIJSON.string(from: updatedAt))",
        ]
    }

    /// One line for `switchboardctl events`:
    ///
    ///     state  pbp=on main=hdmi1 usb=2 hdmi=dualup:1,lg4k:2,samsung:1 controller=up monitor=up error=none
    public var eventLine: String {
        let hdmi = DisplayID.allCases.compactMap { id in hdmiInput[id].map { "\(id.rawValue):\($0)" } }.joined(separator: ",")
        return "state  pbp=\(pbp.rawValue) main=\(mainInput.rawValue) usb=\(usbPort.map(String.init) ?? "?") "
            + "hdmi=\(hdmi.isEmpty ? "?" : hdmi) controller=\(controllerReachable ? "up" : "down") "
            + "monitor=\(dualUpReachable ? "up" : "down") error=\(lastError ?? "none")"
    }
}

extension APIEvent {
    /// The line `switchboardctl events` prints, without the newline.
    ///
    /// Text: `state  pbp=on ...` or `run    step 1/2: ...` (the run event in `RunEvent.line` form).
    /// JSON: `{"data":{...},"event":"state"}` or `{"data":{...},"event":"run"}`, one object per line.
    /// Nil only if the event cannot be encoded, which a well-formed value never does.
    public func line(json: Bool) -> String? {
        switch self {
        case .state(let state):
            return json ? Self.envelope("state", state) : state.eventLine
        case .run(let run):
            return json ? Self.envelope("run", run) : "run    \(run.line)"
        }
    }

    private static func envelope<T: Encodable>(_ name: String, _ value: T) -> String? {
        guard let data = try? APIJSON.makeEncoder().encode(value) else { return nil }
        return #"{"data":"# + String(decoding: data, as: UTF8.self) + #","event":"\#(name)"}"#
    }
}
