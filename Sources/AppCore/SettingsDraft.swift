import Foundation
import StateStore

/// The Settings window's text fields. Converting back goes through `Settings.set(_:to:)`, the same
/// rules `switchboardctl settings set` applies, so the window and the CLI accept and refuse the
/// same values with the same messages.
public struct SettingsDraft: Equatable, Sendable {
    /// `http://host:port`, `host:port`, or empty / `none` for no controller.
    public var controllerURL: String
    public var displayNameContains: String
    public var pollingIntervalSeconds: String
    public var localAPIPort: String

    public init(_ settings: Settings) {
        controllerURL = settings.controllerURL?.absoluteString ?? ""
        displayNameContains = settings.displayNameContains
        pollingIntervalSeconds = settings.text(for: .pollingIntervalSeconds)
        localAPIPort = settings.text(for: .localAPIPort)
    }

    /// `base` with the four fields replaced (`launchAtLogin` is not a text field and is kept).
    /// Throws `SettingsError` naming the first field that does not fit; nothing is half-applied.
    public func settings(applyingTo base: Settings) throws -> Settings {
        var result = base
        try result.set(Settings.Key.controllerURL.rawValue, to: controllerURL)
        try result.set(Settings.Key.displayNameContains.rawValue, to: displayNameContains)
        try result.set(Settings.Key.pollingIntervalSeconds.rawValue, to: pollingIntervalSeconds)
        try result.set(Settings.Key.localAPIPort.rawValue, to: localAPIPort)
        return result
    }
}
