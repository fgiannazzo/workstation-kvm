import DDCKit
import Devices
import ESP32Kit
import Foundation
import StateStore
import SwitchboardCore

/// The composition root: every long-lived object of the app, wired together once. The CLI, the
/// menu bar app (tracer bullet 4) and the local API (tracer bullet 5) all start from here.
///
/// `live` builds the real thing: `VideoCableDDC` and `LGUSBBridge` for the display named in the
/// settings, an `ESP32Client` when a controller address is configured, and a `DisplaySwitch` over
/// BetterDisplay when BetterDisplay is installed. Building it touches no hardware; devices are
/// first used when an action runs or the refresher polls.
public struct Runtime: Sendable {
    public let settings: Settings
    /// The controller address in effect (the environment overrides the settings); nil when none.
    public let controllerURL: URL?
    public let dualUp: LGDualUp
    public let controller: (any ControllerClient)?
    /// `displays.off` and `displays.on`; nil without BetterDisplay.
    public let displays: DisplaySwitch?
    public let store: StateStore
    public let macros: MacroStore
    public let registry: ActionRegistry
    public let context: ActionContext
    public let runner: MacroRunner
    /// Not started by `live`; the app calls `refresher.start()`, the CLI does not.
    public let refresher: StateRefresher

    /// Wires the given devices. Used by `live`, and by tests with fakes.
    ///
    /// - Parameters:
    ///   - appSupport: the directory holding `macros.json`.
    ///   - notify: what the `notify` action does; the app posts a user notification.
    ///   - sleep: the `delay` action's sleep, and the refresher's.
    @MainActor
    public init(
        settings: Settings,
        controllerURL: URL?,
        dualUp: LGDualUp,
        controller: (any ControllerClient)?,
        displays: DisplaySwitch? = nil,
        appSupport: URL,
        notify: @escaping @Sendable (String) async -> Void = { _ in },
        sleep: @escaping Sleeper = Timing.realSleep,
        store: StateStore = StateStore()
    ) {
        let registry = ActionRegistry()
        let macros = MacroStore(directory: appSupport, registry: registry)
        let context = ActionContext(dualUp: dualUp, controller: controller, displays: displays, store: store, notify: notify, sleep: sleep)
        let runner = MacroRunner(registry: registry, macros: macros, context: context)

        self.settings = settings
        self.controllerURL = controllerURL
        self.dualUp = dualUp
        self.controller = controller
        self.displays = displays
        self.store = store
        self.macros = macros
        self.registry = registry
        self.context = context
        self.runner = runner
        self.refresher = StateRefresher(
            dualUp: dualUp,
            controller: controller,
            displays: displays,
            store: store,
            interval: .seconds(max(1, settings.pollingIntervalSeconds)),
            sleep: sleep,
            activity: { await runner.activity }
        )
    }

    /// The production wiring.
    ///
    /// - Parameters:
    ///   - settings: from `SettingsStore`.
    ///   - environment: for `SWITCHBOARD_CONTROLLER_URL`, which overrides `settings.controllerURL`.
    ///   - appSupport: where `macros.json` lives (`AppSupport.directory(environment:)`).
    ///   - notify: what the `notify` action does; the default does nothing beyond the run event.
    ///   - store: the state and log to keep. The menu bar app passes its own when it rebuilds the
    ///     runtime after a settings change, so the log and the last reading survive.
    @MainActor
    public static func live(
        settings: Settings,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        appSupport: URL,
        notify: @escaping @Sendable (String) async -> Void = { _ in },
        store: StateStore = StateStore()
    ) -> Runtime {
        let videoCable = VideoCableDDC(displayNameContains: settings.displayNameContains)
        let usbBridge = LGUSBBridge(displayNameContains: settings.displayNameContains)
        let dualUp = LGDualUp(videoCable: videoCable, usbBridge: usbBridge)

        let controllerURL = settings.effectiveControllerURL(environment: environment)
        let controller = controllerURL.map { ESP32Client(baseURL: $0) }
        let displays = BetterDisplay.installed().map { DisplaySwitch(connector: $0, selectors: settings.displaysToTurnOff) }

        return Runtime(
            settings: settings,
            controllerURL: controllerURL,
            dualUp: dualUp,
            controller: controller,
            displays: displays,
            appSupport: appSupport,
            notify: notify,
            store: store
        )
    }
}
