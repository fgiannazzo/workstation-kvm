import Foundation
import SwitchboardCore

// The words the State section uses, kept out of the views so they are one place and testable.

extension DisplayID {
    public var title: String {
        switch self {
        case .dualup: return "DualUp"
        case .lg4k: return "LG 4K"
        case .samsung: return "Samsung"
        }
    }
}

extension PBPState {
    public var title: String {
        switch self {
        case .on: return "On"
        case .off: return "Off"
        case .unknown: return "Unknown"
        }
    }
}

extension MainInput {
    public var title: String {
        switch self {
        case .hdmi1: return "HDMI 1"
        case .hdmi2: return "HDMI 2"
        case .unknown: return "Unknown"
        }
    }
}

extension DisplaysState {
    public var title: String {
        switch self {
        case .on: return "On"
        case .off: return "Off"
        case .mixed: return "Some off"
        case .unknown: return "Unknown"
        }
    }
}

extension SwitchboardState {
    /// `Port 2`, or `Unknown` before the controller has answered.
    public var usbPortTitle: String {
        usbPort.map { "Port \($0)" } ?? "Unknown"
    }

    /// The assumed input of a display (`HDMI 1`), or nil when the controller has not said.
    public func hdmiInputTitle(for display: DisplayID) -> String? {
        hdmiInput[display].map { "HDMI \($0)" }
    }
}
