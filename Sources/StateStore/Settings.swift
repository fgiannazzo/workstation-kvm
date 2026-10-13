import Foundation

/// The app's settings, stored as `settings.json` in the Application Support directory
/// (`docs/DESIGN.md`, "Names"). Every key has a default, so a missing file, a missing key and a
/// fresh install all behave the same.
public struct Settings: Codable, Sendable, Equatable {
    /// The environment variable that overrides `controllerURL` without touching the file.
    public static let controllerURLEnvironmentKey = "SWITCHBOARD_CONTROLLER_URL"

    /// Where the ESP32 controller (or `switchboardctl controller mock`) listens. Nil: no controller
    /// is configured and the `hdmi.*` and `usb.*` actions throw `controllerUnavailable`.
    public var controllerURL: URL? = nil
    /// Case-insensitive substring of the DualUp's EDID name.
    public var displayNameContains: String = "SDQHD"
    /// Seconds between video-cable polls of the monitor (`StateRefresher`).
    public var pollingIntervalSeconds: Double = 30
    /// Port of the local API on 127.0.0.1 (tracer bullet 5).
    public var localAPIPort: Int = 48600
    /// Start the menu bar app at login (tracer bullet 4).
    public var launchAtLogin: Bool = false
    /// The displays `displays.off` disconnects, by name, EDID serial or UUID as BetterDisplay lists
    /// them. Empty: every physical display.
    public var displaysToTurnOff: [String] = []

    public init(
        controllerURL: URL? = nil,
        displayNameContains: String = "SDQHD",
        pollingIntervalSeconds: Double = 30,
        localAPIPort: Int = 48600,
        launchAtLogin: Bool = false,
        displaysToTurnOff: [String] = []
    ) {
        self.controllerURL = controllerURL
        self.displayNameContains = displayNameContains
        self.pollingIntervalSeconds = pollingIntervalSeconds
        self.localAPIPort = localAPIPort
        self.launchAtLogin = launchAtLogin
        self.displaysToTurnOff = displaysToTurnOff
    }

    // MARK: Controller URL

    /// The controller address in effect: `SWITCHBOARD_CONTROLLER_URL` when it is set to a usable
    /// address, else `controllerURL`. The environment is passed in, never read here, so Codable
    /// and the tests stay pure. An unusable value in the environment is ignored.
    public func effectiveControllerURL(environment: [String: String]) -> URL? {
        if let raw = environment[Self.controllerURLEnvironmentKey], let url = Self.parseControllerURL(raw) {
            return url
        }
        return controllerURL
    }

    /// Whether `SWITCHBOARD_CONTROLLER_URL` is what `effectiveControllerURL` returns.
    public func controllerURLComesFromEnvironment(_ environment: [String: String]) -> Bool {
        guard let raw = environment[Self.controllerURLEnvironmentKey] else { return false }
        return Self.parseControllerURL(raw) != nil
    }

    /// `http://host:port`, or `host:port` which people type without the scheme (read as http).
    /// Nil for an empty string, another scheme, or a missing host.
    public static func parseControllerURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let text = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case controllerURL, displayNameContains, pollingIntervalSeconds, localAPIPort, launchAtLogin, displaysToTurnOff
    }

    /// Missing keys fall back to their defaults, so an older or hand-edited file still loads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let raw = try container.decodeIfPresent(String.self, forKey: .controllerURL), !raw.isEmpty {
            guard let url = Self.parseControllerURL(raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .controllerURL, in: container,
                    debugDescription: "\"\(raw)\" is not a controller address; expected http://host:port"
                )
            }
            controllerURL = url
        }
        displayNameContains = try container.decodeIfPresent(String.self, forKey: .displayNameContains) ?? "SDQHD"
        pollingIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .pollingIntervalSeconds) ?? 30
        localAPIPort = try container.decodeIfPresent(Int.self, forKey: .localAPIPort) ?? 48600
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        displaysToTurnOff = try container.decodeIfPresent([String].self, forKey: .displaysToTurnOff) ?? []
    }

    /// `controllerURL` is left out when nil, the rest is always written, so the file shows every
    /// key that can be edited.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(controllerURL?.absoluteString, forKey: .controllerURL)
        try container.encode(displayNameContains, forKey: .displayNameContains)
        try container.encode(pollingIntervalSeconds, forKey: .pollingIntervalSeconds)
        try container.encode(localAPIPort, forKey: .localAPIPort)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(displaysToTurnOff, forKey: .displaysToTurnOff)
    }
}

// MARK: - Editing by key

/// Why `Settings.set` refused a key or a value. The text is what `switchboardctl settings set`
/// prints.
public struct SettingsError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public let description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}

extension Settings {
    /// The settings that can be edited by name (`switchboardctl settings set <key> <value>`).
    public enum Key: String, CaseIterable, Sendable {
        case controllerURL
        case displayNameContains
        case pollingIntervalSeconds
        case localAPIPort
        case launchAtLogin
        case displaysToTurnOff
    }

    /// Sets one setting from its text form. Throws `SettingsError` for an unknown key or a value
    /// that does not fit; the settings are unchanged then.
    ///
    /// - `controllerURL`: `http://host:port`, `host:port`, or `none` (or empty) to clear it.
    /// - `displayNameContains`: a non-empty substring of the display's EDID name.
    /// - `pollingIntervalSeconds`: a number from 1 to 3600.
    /// - `localAPIPort`: 1 to 65535.
    /// - `launchAtLogin`: `true`/`false` (also `yes`/`no`, `on`/`off`, `1`/`0`).
    /// - `displaysToTurnOff`: names, serials or UUIDs separated by commas, or `all` (or empty) for
    ///   every physical display.
    public mutating func set(_ key: String, to value: String) throws {
        guard let known = Key(rawValue: key) else {
            throw SettingsError("unknown setting \"\(key)\"; keys: \(Key.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch known {
        case .controllerURL:
            if text.isEmpty || text.lowercased() == "none" {
                controllerURL = nil
            } else if let url = Self.parseControllerURL(text) {
                controllerURL = url
            } else {
                throw SettingsError("controllerURL: \"\(value)\" is not a controller address; expected http://host:port, or none to clear")
            }
        case .displayNameContains:
            guard !text.isEmpty else { throw SettingsError("displayNameContains must not be empty") }
            displayNameContains = text
        case .pollingIntervalSeconds:
            guard let seconds = Double(text), seconds.isFinite, (1...3600).contains(seconds) else {
                throw SettingsError("pollingIntervalSeconds must be a number from 1 to 3600, got \"\(value)\"")
            }
            pollingIntervalSeconds = seconds
        case .localAPIPort:
            guard let port = Int(text), (1...65535).contains(port) else {
                throw SettingsError("localAPIPort must be a port number from 1 to 65535, got \"\(value)\"")
            }
            localAPIPort = port
        case .launchAtLogin:
            switch text.lowercased() {
            case "true", "yes", "on", "1": launchAtLogin = true
            case "false", "no", "off", "0": launchAtLogin = false
            default: throw SettingsError("launchAtLogin must be true or false, got \"\(value)\"")
            }
        case .displaysToTurnOff:
            displaysToTurnOff = Self.parseDisplayList(text)
        }
    }

    /// The current value of a setting in the text form `set` accepts.
    public func text(for key: Key) -> String {
        switch key {
        case .controllerURL: return controllerURL?.absoluteString ?? "none"
        case .displayNameContains: return displayNameContains
        case .pollingIntervalSeconds:
            return pollingIntervalSeconds == pollingIntervalSeconds.rounded()
                ? String(Int(pollingIntervalSeconds)) : String(pollingIntervalSeconds)
        case .localAPIPort: return String(localAPIPort)
        case .launchAtLogin: return launchAtLogin ? "true" : "false"
        case .displaysToTurnOff: return displaysToTurnOff.isEmpty ? "all" : displaysToTurnOff.joined(separator: ", ")
        }
    }

    /// `displaysToTurnOff` from its text form: comma-separated entries, `all` or empty for none.
    public static func parseDisplayList(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "all" { return [] }
        return trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
