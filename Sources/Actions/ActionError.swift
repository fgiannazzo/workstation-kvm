import DDCKit
import Devices
import ESP32Kit
import Foundation
import StateStore
import SwitchboardCore

/// Why an action, a macro or a run did not happen or did not finish. `description` is the text a
/// `failed` run event carries and `switchboardctl run` prints.
public enum ActionError: Error, Sendable, Equatable {
    /// Not a macro id and not an action id.
    case unknownID(String)
    /// A required parameter is absent (or null).
    case missingParameter(String)
    /// A parameter is present but wrong: its name and why.
    case invalidParameter(String, String)
    /// The action needs the ESP32 controller and none is configured. The message names the setting
    /// and the environment variable that fix it (`controllerNotConfigured`).
    case controllerUnavailable(String)
    /// The action needs the monitor and it could not be used (not configured, display or USB bridge
    /// missing, bridge busy). The message is the underlying error.
    case monitorUnavailable(String)
    /// `displays.off` or `displays.on` could not ask the display manager (BetterDisplay missing,
    /// not running, or refusing). The message says which.
    case displaysUnavailable(String)
    /// A monitor write went out but the video-cable read-back did not confirm it.
    case unverified(WriteOutcome)
    /// Another run is in progress.
    case busy(runID: String)
    /// A macro's `verify` (or the controller's answer to a command) did not match; one line each.
    case verifyFailed([String])
    /// The controller refused or could not be reached.
    case controller(ControllerError)
    /// The run's task was cancelled before it could finish.
    case cancelled

    /// The message for an action that needs the controller when none is configured.
    public static let controllerNotConfigured = ActionError.controllerUnavailable(
        "no controller is configured: set controllerURL (`switchboardctl settings set controllerURL http://host:port`) "
            + "or the \(Settings.controllerURLEnvironmentKey) environment variable"
    )

    /// The message for `displays.off` and `displays.on` when BetterDisplay is not installed.
    public static let displaysNotConfigured = ActionError.displaysUnavailable(
        "BetterDisplay was not found at /Applications/BetterDisplay.app; displays.off and displays.on use it "
            + "(Pro, Apple silicon) to disconnect and reconnect the displays"
    )

    /// The message for an action that needs the monitor when this process has no transport for it.
    public static let monitorNotConfigured = ActionError.monitorUnavailable("no monitor is configured")

    /// A monitor write that was not confirmed, including the case where 0xD7 could not be read.
    public var isUnverifiedWrite: Bool {
        if case .unverified = self { return true }
        return false
    }

    /// The controller is not configured, did not answer, or timed out: the "check the address and
    /// the network" family (`switchboardctl` exit code 6).
    public var isControllerUnreachable: Bool {
        switch self {
        case .controllerUnavailable:
            return true
        case .controller(let error):
            switch error {
            case .unreachable, .timeout: return true
            case .httpStatus, .invalidResponse: return false
            }
        default:
            return false
        }
    }

    public var isBusy: Bool {
        if case .busy = self { return true }
        return false
    }
}

extension ActionError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case .unknownID(let id):
            return "unknown action or macro \"\(id)\""
        case .missingParameter(let name):
            return "missing parameter \"\(name)\""
        case .invalidParameter(let name, let reason):
            return "invalid parameter \"\(name)\": \(reason)"
        case .controllerUnavailable(let message), .monitorUnavailable(let message), .displaysUnavailable(let message):
            return message
        case .unverified(let outcome):
            let code = "0x" + DDCPacket.hexString([outcome.command.code])
            let expected = "expected \(outcome.expected) (\(outcome.command.targetState.rawValue))"
            if let observed = outcome.observed {
                let meaning = DualUpReading.pbpState(from: observed)
                let shown = meaning == .unknown ? "unexpected value" : meaning.rawValue
                return "unverified: \(code) read back \(observed) (\(shown)), \(expected)"
            }
            return "unverified: \(code) unreadable, \(expected)"
        case .busy(let runID):
            return "another run is in progress (run \(runID))"
        case .verifyFailed(let lines):
            return "verify failed: " + lines.joined(separator: "; ")
        case .controller(let error):
            return error.description
        case .cancelled:
            return "cancelled"
        }
    }

    public var errorDescription: String? { description }
}
