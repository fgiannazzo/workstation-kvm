import Actions
import Foundation
import SwitchboardCore

/// Why a `switchboard://` URL is not something the app will run. `description` is the text the
/// app logs and shows in a notification.
public enum SwitchboardURLError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// Not `switchboard:`.
    case wrongScheme(String?)
    /// Only `switchboard://run/...` exists.
    case unsupportedHost(String?)
    /// `switchboard://run` or `switchboard://run/`.
    case missingID
    /// The path after `run/` is more than one component.
    case unexpectedPath(String)
    /// The id has characters a macro or action id cannot have.
    case invalidID(String)
    /// A query item that cannot be turned into a parameter: no name, no value, or a repeated name.
    case badParameter(String)

    public var description: String {
        switch self {
        case .wrongScheme(let scheme):
            return "not a switchboard:// URL (scheme \(scheme.map { "\"\($0)\"" } ?? "missing"))"
        case .unsupportedHost(let host):
            return "unsupported URL \(host.map { "\"\($0)\"" } ?? "without a host"); use switchboard://run/{id}"
        case .missingID:
            return "the URL has no id; use switchboard://run/{id}"
        case .unexpectedPath(let path):
            return "unexpected path \"\(path)\"; use switchboard://run/{id}"
        case .invalidID(let id):
            return "\"\(id)\" is not a valid macro or action id (letters, digits, \".\", \"_\" or \"-\")"
        case .badParameter(let detail):
            return "bad parameter: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}

/// The `switchboard://run/{id}` URL scheme (`docs/API.md`, "URL scheme"). It behaves like
/// `POST /run/{id}` without a token: the OS only hands these URLs to the app.
///
///     switchboard://run/guest
///     switchboard://run/usb.select?port=2
///
/// Parsing is structural. The query values of an action id become typed parameters through
/// `ActionDescriptor.parameters(fromText:)` (so `port=2` is the integer 2), but whether they are
/// acceptable (`port=9`, `port=abc`) is the runner's call and comes back as a failed run, because
/// a macro with the same id would ignore them. A macro id's query is kept as plain strings and
/// ignored by the runner.
public enum SwitchboardURL {
    public static let scheme = "switchboard"
    public static let runHost = "run"

    /// `switchboard://run/{id}[?key=value&...]` as the id to run and its parameters.
    public static func parse(_ url: URL) throws -> (id: String, parameters: [String: JSONValue]) {
        try parse(url, registry: ActionRegistry())
    }

    static func parse(_ url: URL, registry: ActionRegistry) throws -> (id: String, parameters: [String: JSONValue]) {
        guard url.scheme?.lowercased() == scheme else { throw SwitchboardURLError.wrongScheme(url.scheme) }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SwitchboardURLError.unsupportedHost(nil)
        }
        let host = components.host.flatMap { $0.isEmpty ? nil : $0 }
        guard host?.lowercased() == runHost else { throw SwitchboardURLError.unsupportedHost(host) }

        // "/guest" or "/guest/": one component, a trailing slash is forgiven.
        var path = components.path
        if path.hasPrefix("/") { path.removeFirst() }
        if path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty else { throw SwitchboardURLError.missingID }
        guard !path.contains("/") else { throw SwitchboardURLError.unexpectedPath(components.path) }
        guard MacroValidator.isValidID(path) else { throw SwitchboardURLError.invalidID(path) }

        var text: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard !item.name.isEmpty else { throw SwitchboardURLError.badParameter("a parameter has no name") }
            guard let value = item.value else { throw SwitchboardURLError.badParameter("\"\(item.name)\" has no value (write \(item.name)=...)") }
            guard text[item.name] == nil else { throw SwitchboardURLError.badParameter("\"\(item.name)\" is given more than once") }
            text[item.name] = value
        }

        let parameters: [String: JSONValue]
        if let action = ActionID(rawValue: path) {
            parameters = registry.descriptor(for: action).parameters(fromText: text)
        } else {
            parameters = text.mapValues { .string($0) }
        }
        return (id: path, parameters: parameters)
    }
}
