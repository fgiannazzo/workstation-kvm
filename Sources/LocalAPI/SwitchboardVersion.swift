import Foundation

/// The one place the product version lives. `GET /health` reports it; the menu bar app and
/// `switchboardctl` print it.
public enum SwitchboardVersion {
    public static let current = "0.1.0"
}
