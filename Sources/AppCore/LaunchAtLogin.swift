import Foundation
import ServiceManagement

/// Whether the app starts at login, as macOS reports it (`SMAppService.mainApp.status`).
public enum LaunchAtLoginStatus: Sendable, Equatable {
    /// Registered and approved.
    case enabled
    /// Registered, but the user has to approve it in System Settings > General > Login Items.
    case requiresApproval
    case notRegistered
    /// macOS cannot find the app as a login item (an unsigned or oddly placed bundle).
    case notFound
    /// Not running from an `.app`: `swift run` has no bundle to register.
    case notInBundle

    /// The toggle's position: on once the app is registered, even while approval is pending.
    public var isOn: Bool {
        self == .enabled || self == .requiresApproval
    }
}

public struct LaunchAtLoginError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    public let description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }

    /// What `SMAppService` cannot do outside a bundle.
    public static let notInBundle = LaunchAtLoginError(
        "launch at login only works from the app bundle: build it with `make app` and open dist/Switchboard.app"
    )
}

/// The login item, behind a protocol so `AppModel` is tested without touching the system's.
public protocol LaunchAtLoginService: Sendable {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
    /// System Settings > General > Login Items, where a pending approval is granted.
    func openSystemSettings()
}

/// `SMAppService.mainApp`: the app's own bundle as a login item.
public struct MainAppLoginItem: LaunchAtLoginService {
    public init() {}

    /// `SMAppService` needs a bundle; a SwiftPM executable run directly has none.
    static var isInBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    public var status: LaunchAtLoginStatus {
        guard Self.isInBundle else { return .notInBundle }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .notRegistered
        }
    }

    public func register() throws {
        guard Self.isInBundle else { throw LaunchAtLoginError.notInBundle }
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        guard Self.isInBundle else { throw LaunchAtLoginError.notInBundle }
        try SMAppService.mainApp.unregister()
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
