import DDCKit
import Devices
import Foundation
import StateStore
import SwitchboardCore

/// Everything an action may touch. Each device is optional: with no controller the `hdmi.*` and
/// `usb.*` actions throw `ActionError.controllerUnavailable`, with no monitor the `monitor.*`
/// actions throw `monitorUnavailable`, without BetterDisplay `displays.*` throw `displaysUnavailable`.
public struct ActionContext: Sendable {
    /// The LG DualUp: `monitor.*`.
    public var dualUp: LGDualUp?
    /// The ESP32 controller: `hdmi.*` and `usb.*`.
    public var controller: (any ControllerClient)?
    /// The physical displays' connection, through BetterDisplay: `displays.*`.
    public var displays: DisplaySwitch?
    /// Where actions record what they read and what they did.
    public var store: StateStore
    /// `notify`. The menu bar app posts a user notification here; the CLI has nothing to show
    /// beyond the run event, so its closure does nothing.
    public var notify: @Sendable (String) async -> Void
    /// `delay`. Production passes `Timing.realSleep`; tests pass a closure that returns at once.
    public var sleep: Sleeper

    public init(
        dualUp: LGDualUp?,
        controller: (any ControllerClient)?,
        displays: DisplaySwitch? = nil,
        store: StateStore,
        notify: @escaping @Sendable (String) async -> Void = { _ in },
        sleep: @escaping Sleeper = Timing.realSleep
    ) {
        self.dualUp = dualUp
        self.controller = controller
        self.displays = displays
        self.store = store
        self.notify = notify
        self.sleep = sleep
    }
}
