import Foundation
import SwitchboardCore

/// The eight actions (`docs/DESIGN.md`, "Actions"; `docs/API.md`, `GET /actions`). The raw values
/// are the stable ids used by macros, the API and the Stream Deck.
public enum ActionID: String, Codable, CaseIterable, Sendable, Hashable {
    case monitorPBPOn = "monitor.pbp.on"
    case monitorPBPOff = "monitor.pbp.off"
    case monitorRead = "monitor.read"
    case hdmiSelect = "hdmi.select"
    case hdmiResync = "hdmi.resync"
    case usbSelect = "usb.select"
    case delay = "delay"
    case notify = "notify"

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let id = ActionID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown action \"\(raw)\"; actions: \(Self.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }
        self = id
    }
}

/// One parameter of an action, encoded like the entries of `GET /actions`:
/// `{ "name": "port", "type": "int", "min": 1, "max": 4 }`, `values` for an enum, and no
/// `min`/`max`/`values` keys where they do not apply.
public struct ParameterDescriptor: Codable, Sendable, Equatable {
    public enum ParameterType: String, Codable, Sendable {
        case string
        case int
        /// One of `values`. The wire name is `enum`.
        case choice = "enum"
    }

    public var name: String
    public var type: ParameterType
    public var values: [String]?
    public var min: Int?
    public var max: Int?

    public init(name: String, type: ParameterType, values: [String]? = nil, min: Int? = nil, max: Int? = nil) {
        self.name = name
        self.type = type
        self.values = values
        self.min = min
        self.max = max
    }

    public static func choice(_ name: String, values: [String]) -> ParameterDescriptor {
        ParameterDescriptor(name: name, type: .choice, values: values)
    }

    public static func int(_ name: String, min: Int, max: Int) -> ParameterDescriptor {
        ParameterDescriptor(name: name, type: .int, min: min, max: max)
    }

    public static func string(_ name: String) -> ParameterDescriptor {
        ParameterDescriptor(name: name, type: .string)
    }

    /// A command-line or URL-query value as the JSON the parameter expects: an integer for `int`
    /// when the text is one, the text otherwise (so validation reports it instead of guessing).
    public func value(fromText text: String) -> JSONValue {
        if type == .int, let number = Int(text.trimmingCharacters(in: .whitespaces)) {
            return .int(number)
        }
        return .string(text)
    }
}

/// One entry of `GET /actions`: `{ "id": "usb.select", "title": "USB to port", "parameters": [...] }`.
public struct ActionDescriptor: Codable, Sendable, Equatable, Identifiable {
    public var id: ActionID
    public var title: String
    /// Always encoded, as `[]` for an action without parameters.
    public var parameters: [ParameterDescriptor]

    public init(id: ActionID, title: String, parameters: [ParameterDescriptor] = []) {
        self.id = id
        self.title = title
        self.parameters = parameters
    }

    /// Converts `key=value` text (the CLI, a URL query) to typed parameters using this action's
    /// descriptors. A key the action does not declare stays a string so validation can name it.
    public func parameters(fromText text: [String: String]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (key, value) in text {
            if let descriptor = parameters.first(where: { $0.name == key }) {
                result[key] = descriptor.value(fromText: value)
            } else {
                result[key] = .string(value)
            }
        }
        return result
    }

    /// `usb.select  USB to port  port:int(1-4)`, for listings.
    public var signature: String {
        let list = parameters.map { parameter -> String in
            switch parameter.type {
            case .int: return "\(parameter.name):int(\(parameter.min ?? 0)-\(parameter.max ?? 0))"
            case .choice: return "\(parameter.name):\((parameter.values ?? []).joined(separator: "|"))"
            case .string: return "\(parameter.name):string"
            }
        }
        return list.joined(separator: " ")
    }
}

/// The body of `GET /actions`: `{ "actions": [...] }`.
public struct ActionList: Codable, Sendable, Equatable {
    public var actions: [ActionDescriptor]

    public init(actions: [ActionDescriptor]) {
        self.actions = actions
    }
}
