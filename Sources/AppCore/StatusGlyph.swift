import Foundation
import SwitchboardCore

/// How the menu bar glyph is coloured. The view layer maps these to colours.
public enum Tint: Sendable, Equatable {
    /// The system's menu bar colour (a template image).
    case primary
    /// Dimmed: the DualUp is not answering, so the glyph shows the last thing known.
    case secondary
    /// Something failed (`SwitchboardState.lastError` is set).
    case red
}

/// The menu bar glyph for a state.
public enum StatusGlyph {
    /// PBP on: `rectangle.split.1x2`; off: `rectangle`; unknown: `questionmark.square.dashed`.
    ///
    /// The tint is red when `lastError` is set (an error outranks everything), secondary when the
    /// DualUp is unreachable (including before the first read), primary otherwise.
    public static func symbol(for state: SwitchboardState) -> (name: String, tint: Tint) {
        let name: String
        switch state.pbp {
        case .on: name = "rectangle.split.1x2"
        case .off: name = "rectangle"
        case .unknown: name = "questionmark.square.dashed"
        }
        let tint: Tint
        if state.lastError != nil {
            tint = .red
        } else if !state.dualUpReachable {
            tint = .secondary
        } else {
            tint = .primary
        }
        return (name, tint)
    }
}
