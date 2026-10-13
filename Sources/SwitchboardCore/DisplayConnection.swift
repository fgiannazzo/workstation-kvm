import Foundation

/// Whether the Mac drives the physical displays that `displays.off` turns off. `off` means macOS
/// has disconnected them (they sleep for lack of signal), `mixed` that some are and some are not,
/// `unknown` that nothing could be read (no display manager, or none of the displays listed).
public enum DisplaysState: String, Codable, Sendable, Hashable {
    case on
    case off
    case mixed
    case unknown

    /// `on` when every display is connected, `off` when none is, `mixed` otherwise, `unknown`
    /// for an empty list.
    public static func aggregate(_ connected: [Bool]) -> DisplaysState {
        if connected.isEmpty { return .unknown }
        if connected.allSatisfy({ $0 }) { return .on }
        if connected.allSatisfy({ !$0 }) { return .off }
        return .mixed
    }
}

/// One physical display as the display manager knows it. `uuid` is the macOS display UUID, which
/// addresses it; `serial` is the EDID's alphanumeric serial, when it has one.
public struct ManagedDisplay: Codable, Sendable, Hashable {
    public var name: String
    public var uuid: String
    public var serial: String?

    public init(name: String, uuid: String, serial: String? = nil) {
        self.name = name
        self.uuid = uuid
        self.serial = serial
    }

    /// Whether a `displaysToTurnOff` entry names this display: its name, serial or UUID, ignoring
    /// case and surrounding spaces.
    public func matches(_ selector: String) -> Bool {
        let wanted = selector.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return false }
        return [name, uuid, serial ?? ""].contains { $0.lowercased() == wanted }
    }
}

/// Connects and disconnects physical displays in macOS's display configuration. A disconnected
/// display leaves the layout and gets no signal, so it goes to standby; no command is sent to the
/// monitor. The live implementation is `BetterDisplay` (module `Devices`); tests use
/// `FakeDisplayConnector`.
public protocol DisplayConnector: Sendable {
    /// The physical displays it manages: hardware-backed, never virtual screens or the virtual
    /// display of a remote-desktop session.
    func displays() async throws -> [ManagedDisplay]
    /// Whether the display is connected; nil when the connector does not know it.
    func isConnected(_ display: ManagedDisplay) async throws -> Bool?
    /// Asks for the display to be connected or disconnected. Success means the request was
    /// accepted, not that it happened: read it back with `isConnected`.
    func setConnected(_ display: ManagedDisplay, _ connected: Bool) async throws
    /// Connects every display it can, including ones it no longer lists.
    func connectAll() async throws
}
