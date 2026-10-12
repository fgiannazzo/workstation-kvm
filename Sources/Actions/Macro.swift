import Foundation
import SwitchboardCore

/// A coding key for objects whose keys are not known up front.
struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// One step of a macro: an action plus its parameters. On the wire the parameters are sibling
/// keys of `action`: `{ "action": "usb.select", "port": 2 }`.
public struct MacroStep: Codable, Sendable, Equatable {
    public var action: ActionID
    public var parameters: [String: JSONValue]

    public init(action: ActionID, parameters: [String: JSONValue] = [:]) {
        self.action = action
        self.parameters = parameters
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        let actionKey = AnyKey("action")
        guard container.contains(actionKey) else {
            throw DecodingError.keyNotFound(actionKey, .init(codingPath: decoder.codingPath, debugDescription: "a step needs an \"action\""))
        }
        action = try container.decode(ActionID.self, forKey: actionKey)
        var parameters: [String: JSONValue] = [:]
        for key in container.allKeys where key.stringValue != "action" {
            parameters[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        self.parameters = parameters
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        if parameters["action"] != nil {
            throw EncodingError.invalidValue(parameters, .init(codingPath: encoder.codingPath, debugDescription: "\"action\" is not a parameter name"))
        }
        try container.encode(action, forKey: AnyKey("action"))
        for (key, value) in parameters {
            try container.encode(value, forKey: AnyKey(key))
        }
    }

    /// `usb.select port=2`, for listings and logs.
    public var summary: String {
        let list = parameters.keys.sorted().map { key -> String in
            let value = parameters[key] ?? .null
            return "\(key)=\(value.stringValue ?? value.description)"
        }
        return ([action.rawValue] + list).joined(separator: " ")
    }
}

/// What must be true of `SwitchboardState` after a macro's last step. Every field is optional;
/// the ones that are present must match.
public struct MacroVerify: Codable, Sendable, Equatable {
    public var pbp: PBPState?
    public var mainInput: MainInput?
    public var usbPort: Int?
    /// Displays whose assumed input must match; other displays are not checked.
    public var hdmiInput: [DisplayID: Int]?

    public init(pbp: PBPState? = nil, mainInput: MainInput? = nil, usbPort: Int? = nil, hdmiInput: [DisplayID: Int]? = nil) {
        self.pbp = pbp
        self.mainInput = mainInput
        self.usbPort = usbPort
        self.hdmiInput = hdmiInput
    }

    /// Nothing to check.
    public var isEmpty: Bool {
        pbp == nil && mainInput == nil && usbPort == nil && (hdmiInput?.isEmpty ?? true)
    }

    private static let knownKeys = ["pbp", "mainInput", "usbPort", "hdmiInput"]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        if let unknown = container.allKeys.map(\.stringValue).sorted().first(where: { !Self.knownKeys.contains($0) }) {
            throw DecodingError.dataCorruptedError(
                forKey: AnyKey(unknown), in: container,
                debugDescription: "unknown verify key \"\(unknown)\"; keys: \(Self.knownKeys.joined(separator: ", "))"
            )
        }
        pbp = try container.decodeIfPresent(PBPState.self, forKey: AnyKey("pbp"))
        mainInput = try container.decodeIfPresent(MainInput.self, forKey: AnyKey("mainInput"))
        usbPort = try container.decodeIfPresent(Int.self, forKey: AnyKey("usbPort"))
        if let keyed = try container.decodeIfPresent([String: Int].self, forKey: AnyKey("hdmiInput")) {
            var inputs: [DisplayID: Int] = [:]
            for (name, input) in keyed {
                guard let display = DisplayID(rawValue: name) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: AnyKey("hdmiInput"), in: container,
                        debugDescription: "unknown display \"\(name)\"; displays: \(DisplayID.allCases.map(\.rawValue).joined(separator: ", "))"
                    )
                }
                inputs[display] = input
            }
            hdmiInput = inputs
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        try container.encodeIfPresent(pbp, forKey: AnyKey("pbp"))
        try container.encodeIfPresent(mainInput, forKey: AnyKey("mainInput"))
        try container.encodeIfPresent(usbPort, forKey: AnyKey("usbPort"))
        if let hdmiInput {
            // `[DisplayID: Int]` would encode as an array; the wire format is an object.
            var keyed: [String: Int] = [:]
            for (display, input) in hdmiInput { keyed[display.rawValue] = input }
            try container.encode(keyed, forKey: AnyKey("hdmiInput"))
        }
    }

    /// The fields that do not match, one line each (`usbPort: expected 2, got 1`); empty when the
    /// state satisfies the verify.
    public func mismatches(in state: SwitchboardState) -> [String] {
        var lines: [String] = []
        if let pbp, state.pbp != pbp {
            lines.append("pbp: expected \(pbp.rawValue), got \(state.pbp.rawValue)")
        }
        if let mainInput, state.mainInput != mainInput {
            lines.append("mainInput: expected \(mainInput.rawValue), got \(state.mainInput.rawValue)")
        }
        if let usbPort, state.usbPort != usbPort {
            lines.append("usbPort: expected \(usbPort), got \(state.usbPort.map(String.init) ?? "unknown")")
        }
        if let hdmiInput {
            for display in DisplayID.allCases {
                guard let expected = hdmiInput[display], state.hdmiInput[display] != expected else { continue }
                lines.append("hdmiInput.\(display.rawValue): expected \(expected), got \(state.hdmiInput[display].map(String.init) ?? "unknown")")
            }
        }
        return lines
    }

    /// `pbp=on usbPort=2`, for listings.
    public var summary: String {
        var parts: [String] = []
        if let pbp { parts.append("pbp=\(pbp.rawValue)") }
        if let mainInput { parts.append("mainInput=\(mainInput.rawValue)") }
        if let usbPort { parts.append("usbPort=\(usbPort)") }
        if let hdmiInput {
            for display in DisplayID.allCases {
                if let input = hdmiInput[display] { parts.append("hdmiInput.\(display.rawValue)=\(input)") }
            }
        }
        return parts.joined(separator: " ")
    }
}

/// An ordered list of steps with an optional verify. Aborts on the first failing step.
public struct Macro: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var steps: [MacroStep]
    public var verify: MacroVerify?

    public init(id: String, name: String, steps: [MacroStep], verify: MacroVerify? = nil) {
        self.id = id
        self.name = name
        self.steps = steps
        self.verify = verify
    }
}

/// The contents of `macros.json` and the body of `GET /macros`: `{ "macros": [...] }`.
public struct MacroFile: Codable, Sendable, Equatable {
    public var macros: [Macro]

    public init(macros: [Macro]) {
        self.macros = macros
    }
}
