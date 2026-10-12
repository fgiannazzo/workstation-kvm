import Actions
import Foundation

/// How a failed run ended, for a client that has only the `failed` event to go on.
///
/// In process, `MacroRunner` hands back the `ActionError`. Over the API the `run` event carries
/// text only (`docs/API.md` has no error code on it), so `switchboardctl` recovers the two
/// families it gives their own exit code from the message: `<action id>: <ActionError.description>`.
/// The phrases are the ones `ActionError` and `ControllerError` produce; a test builds each real
/// error and checks it is recognised, so a reworded message fails there instead of quietly
/// turning exit 6 into exit 1.
public enum RunFailureKind: Sendable, Equatable {
    /// A monitor write went out and the video-cable read-back did not confirm it.
    case unverifiedWrite
    /// The controller is not configured, did not answer, or timed out.
    case controllerUnreachable
    /// Anything else: a refusal by the controller, a failed `verify`, a missing monitor, ...
    case other
}

extension RunEvent {
    /// Nil unless `status` is `failed`.
    public var failureKind: RunFailureKind? {
        guard status == .failed else { return nil }
        return Self.classify(message)
    }

    static func classify(_ message: String) -> RunFailureKind {
        if message.contains(": unverified: 0x") {
            return .unverifiedWrite
        }
        let controllerPhrases = [
            "no controller is configured",
            "controller unreachable at ",
            "controller did not answer in time",
        ]
        if controllerPhrases.contains(where: { message.contains($0) }) {
            return .controllerUnreachable
        }
        return .other
    }
}
