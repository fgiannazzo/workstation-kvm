import Actions
import ESP32Kit
import Foundation
import LocalAPI
import Observation
import os
import StateStore
import SwitchboardCore

/// How a run requested through `AppModel` ended.
public struct RunOutcome: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// The run started and every step (and the macro's `verify`) passed.
        case finished
        /// The run started and failed: a step failed, a monitor write was not verified, `verify` did not match.
        case failed
        /// The run never started: an unknown id, a missing parameter, or another run is in progress.
        case rejected
    }

    /// The macro or action id that was asked for.
    public var id: String
    public var status: Status
    /// `ok`, or the reason.
    public var message: String
    /// The runner's report; nil for a rejected run.
    public var report: RunReport?

    public init(id: String, status: Status, message: String, report: RunReport? = nil) {
        self.id = id
        self.status = status
        self.message = message
        self.report = report
    }

    public var succeeded: Bool { status == .finished }
}

/// Where the local API stands. Settings shows it; `switchboardctl` and the Stream Deck plugin talk
/// to it. The server runs inside the app process beside the UI (`AppModel.startServices`).
public enum APIStatus: Equatable, Sendable {
    case stopped
    case starting
    case running(URL)
    case failed(String)

    /// The base URL while the server listens.
    public var url: URL? {
        if case .running(let url) = self { return url }
        return nil
    }
}

/// The menu bar app's model: owns the `Runtime`, mirrors its state for SwiftUI and carries out what
/// the UI and the URL scheme ask for. Every decision that is not drawing lives here or in the
/// other `AppCore` types, so it is tested without a window.
///
/// Life cycle: `init` builds a `Runtime` from the default settings (this touches no hardware);
/// `start()` loads `settings.json` and `macros.json`, rebuilds the runtime if the settings differ,
/// starts the `StateRefresher` (reads only) and the services. Nothing in `init` or `start()` writes
/// to the monitor or the controller; those happen only when a run is requested.
@MainActor
@Observable
public final class AppModel {
    /// Builds a `Runtime` for the given settings, around the given store and `notify` action.
    /// Production wraps `Runtime.live`; tests build one over fakes.
    public typealias RuntimeFactory = @MainActor (
        _ settings: Settings,
        _ store: StateStore,
        _ notify: @escaping @Sendable (String) async -> Void
    ) -> Runtime

    /// Looks for a controller over mDNS for at most the given time.
    public typealias Discovery = @Sendable (Duration) async -> DiscoveredController?

    public static let logSubsystem = "io.github.fgiannazzo.switchboard"

    // MARK: Observable state

    /// The wiring in use. Replaced when a setting that the wiring is built from changes.
    public private(set) var runtime: Runtime
    public private(set) var settings: Settings
    public private(set) var macros: [Macro] = []
    /// Why `macros.json` could not be loaded; the editor refuses to overwrite a file it could not read.
    public private(set) var macrosError: String?
    /// Why `settings.json` could not be loaded (the defaults are in use then).
    public private(set) var startupError: String?
    public private(set) var runProgress = RunProgress()
    /// A run requested through this model is in progress. The controls disable themselves meanwhile.
    public private(set) var isBusy = false
    public private(set) var launchAtLoginStatus: LaunchAtLoginStatus
    /// What to tell the user about the last launch-at-login change (approval pending, error, no bundle).
    public private(set) var launchAtLoginMessage: String?
    /// The local API server (tracer bullet 5) as started by `startServices()`.
    public private(set) var apiStatus: APIStatus = .stopped
    /// The bearer token the API expects, once the server has started (read from the keychain,
    /// created on first launch). Settings shows it with a Copy button; `switchboardctl token` prints it.
    public private(set) var apiToken: String?

    /// What the monitor and the controller last reported (`runtime.store.state`).
    public var state: SwitchboardState { runtime.store.state }
    /// The log, oldest first (`runtime.store.log`).
    public var log: [LogEntry] { runtime.store.log }
    /// The actions the editor and the controls offer.
    public var actions: [ActionDescriptor] { runtime.registry.descriptors }
    /// The controller address in effect (the environment overrides the saved one).
    public var controllerURL: URL? { runtime.controllerURL }
    /// Whether `displays.off` and `displays.on` can run (BetterDisplay is installed).
    public var canSwitchDisplays: Bool { runtime.displays != nil }
    public var controllerURLComesFromEnvironment: Bool { settings.controllerURLComesFromEnvironment(environment) }

    // MARK: Fixed

    /// `~/Library/Application Support/Switchboard/`, or `SWITCHBOARD_SUPPORT_DIR`.
    public let supportDirectory: URL
    public let environment: [String: String]

    @ObservationIgnored private let store: StateStore
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let runtimeFactory: RuntimeFactory
    @ObservationIgnored private let notifier: any UserNotifier
    @ObservationIgnored private let loginItem: any LaunchAtLoginService
    @ObservationIgnored private let discovery: Discovery
    @ObservationIgnored private let tokenStore: any TokenStoring
    @ObservationIgnored private var apiServer: LocalAPIServer?
    @ObservationIgnored private var servicesTask: Task<Void, Never>?
    @ObservationIgnored private let notifyAction: @Sendable (String) async -> Void
    @ObservationIgnored private let logger = Logger(subsystem: AppModel.logSubsystem, category: "app")
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var pendingRebuild = false

    /// - Parameters:
    ///   - environment: for `SWITCHBOARD_SUPPORT_DIR` and `SWITCHBOARD_CONTROLLER_URL`.
    ///   - supportDirectory: where `settings.json` and `macros.json` live; default from `environment`.
    ///   - runtimeFactory: how to build the `Runtime`; default `Runtime.live`.
    ///   - notifier: shows notifications (the `notify` action, URL failures).
    ///   - loginItem: the launch-at-login service.
    ///   - discovery: the mDNS lookup behind the Settings window's Discover button.
    ///   - tokenStore: where the local API token lives; the keychain in the app, a file in tests.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        supportDirectory: URL? = nil,
        runtimeFactory: RuntimeFactory? = nil,
        notifier: any UserNotifier = SystemNotifier(),
        loginItem: any LaunchAtLoginService = MainAppLoginItem(),
        discovery: @escaping Discovery = { await ESP32Discovery.first(timeout: $0) },
        tokenStore: any TokenStoring = KeychainTokenStore()
    ) {
        let directory = supportDirectory ?? AppSupport.directory(environment: environment)
        let store = StateStore()
        let notifyAction = Self.makeNotify(notifier: notifier, store: store)
        let factory: RuntimeFactory = runtimeFactory ?? { settings, store, notify in
            Runtime.live(settings: settings, environment: environment, appSupport: directory, notify: notify, store: store)
        }

        self.environment = environment
        self.supportDirectory = directory
        self.store = store
        self.settingsStore = SettingsStore(directory: directory)
        self.runtimeFactory = factory
        self.notifier = notifier
        self.loginItem = loginItem
        self.discovery = discovery
        self.tokenStore = tokenStore
        self.notifyAction = notifyAction
        self.settings = Settings()
        self.runtime = factory(Settings(), store, notifyAction)
        self.launchAtLoginStatus = loginItem.status
    }

    // MARK: Start and stop

    /// Loads the settings and the macros, starts the refresher and the services. Idempotent: a
    /// second call (the URL handler calls it too) waits for the first.
    public func start() async {
        if startTask == nil {
            startTask = Task { await performStart() }
        }
        await startTask?.value
    }

    private func performStart() async {
        do {
            let loaded = try await settingsStore.load()
            if loaded != settings {
                settings = loaded
                rebuildRuntime()
            }
        } catch {
            startupError = Self.describe(error)
            record(.error, "settings: \(Self.describe(error)); using the defaults")
        }
        await reloadMacros()
        launchAtLoginStatus = loginItem.status

        runtime.refresher.start()
        isStarted = true
        startServices()
        record(.info, "started; controller \(runtime.controllerURL?.absoluteString ?? "none"), display \"\(settings.displayNameContains)\", files in \(supportDirectory.path(percentEncoded: false))")
    }

    /// Stops polling. The app calls it when it quits; tests call it so nothing outlives them.
    public func stop() {
        runtime.refresher.stop()
        isStarted = false
    }

    // MARK: Services

    /// Starts the local API (`LocalAPI`, 127.0.0.1 and `settings.localAPIPort`) over the current
    /// runtime. Called at the end of `start()` and again after every runtime rebuild, so it first
    /// stops the server it started before. The token comes from `tokenStore` (the keychain in the
    /// app), created on first launch. Failures (port in use, keychain denied) land in `apiStatus`
    /// and the log; the rest of the app keeps working.
    func startServices() {
        servicesTask?.cancel()
        let previous = apiServer
        apiServer = nil
        apiStatus = .starting
        let runtime = runtime
        servicesTask = Task { [weak self] in
            await previous?.stop()
            guard let self, !Task.isCancelled else { return }
            await self.startLocalAPI(for: runtime)
        }
    }

    private func startLocalAPI(for runtime: Runtime) async {
        let port = runtime.settings.localAPIPort
        guard (0...Int(UInt16.max)).contains(port) else {
            apiStatus = .failed("invalid port \(port)")
            record(.error, "local API: invalid port \(port)")
            return
        }
        do {
            let token = try TokenStore.loadOrCreate(using: tokenStore)
            apiToken = token
            let server = LocalAPIServer(runtime: runtime, port: UInt16(port), token: token)
            try await server.start()
            if Task.isCancelled {
                await server.stop()
                return
            }
            apiServer = server
            let url = URL(string: "http://127.0.0.1:\(await server.port)")!
            apiStatus = .running(url)
            record(.info, "local API listening on \(url.absoluteString)")
        } catch {
            apiStatus = .failed(Self.describe(error))
            record(.error, "local API: \(Self.describe(error))")
        }
    }

    /// Stops the local API and waits until the port is released.
    public func stopServices() async {
        servicesTask?.cancel()
        servicesTask = nil
        let server = apiServer
        apiServer = nil
        await server?.stop()
        apiStatus = .stopped
    }

    /// `stop()` plus waiting for the services to end. Tests call this so nothing outlives them;
    /// the app calls `stop()` on termination and lets the process exit close the socket.
    public func shutdown() async {
        stop()
        await stopServices()
    }

    // MARK: Running

    /// Runs a macro, or an action with parameters, through `MacroRunner.execute` and keeps
    /// `runProgress` current while it goes. One run at a time: a request while `isBusy` (or while a
    /// run started by someone else, such as the local API, is in progress) is `rejected`.
    @discardableResult
    public func run(id: String, parameters: [String: JSONValue] = [:]) async -> RunOutcome {
        guard !isBusy else {
            record(.warning, "run \(id) refused: another run is in progress")
            return RunOutcome(id: id, status: .rejected, message: "another run is in progress")
        }
        isBusy = true
        defer {
            isBusy = false
            applyPendingRebuild()
        }

        // The runner reports from its own actor; a stream carries the events back in order.
        let (events, continuation) = AsyncStream<RunEvent>.makeStream()
        let consumer = Task {
            for await event in events { runProgress.apply(event) }
        }

        do {
            let report = try await runtime.runner.execute(id: id, parameters: parameters) { event in
                _ = continuation.yield(event)
            }
            continuation.finish()
            await consumer.value
            return RunOutcome(
                id: id,
                status: report.succeeded ? .finished : .failed,
                message: report.terminal.message,
                report: report
            )
        } catch {
            continuation.finish()
            await consumer.value
            let message = Self.describe(error)
            if let action = error as? ActionError, action.isBusy {
                // Someone else's run (the local API) holds the runner; leave their progress alone.
                record(.warning, "run \(id) refused: \(message)")
                return RunOutcome(id: id, status: .rejected, message: message)
            }
            runProgress.reject(id: id, message: message)
            record(.error, "run \(id) not started: \(message)")
            return RunOutcome(id: id, status: .rejected, message: message)
        }
    }

    @discardableResult
    public func run(_ action: ActionID, parameters: [String: JSONValue] = [:]) async -> RunOutcome {
        await run(id: action.rawValue, parameters: parameters)
    }

    /// The one-click correction for the OREI switches, whose position cannot be read: the
    /// controller is told which input the display is really on (`hdmi.resync`), without pulsing.
    @discardableResult
    public func resyncHDMI(display: DisplayID, input: Int) async -> RunOutcome {
        await run(.hdmiResync, parameters: ["display": .string(display.rawValue), "input": .int(input)])
    }

    /// A `switchboard://run/{id}` URL: parse it and run it. A URL that does not parse, and a run
    /// that does not finish, are logged and shown as a notification, because a Stream Deck key has
    /// no other place to say what went wrong. Returns nil when the URL does not parse.
    @discardableResult
    public func handle(url: URL) async -> RunOutcome? {
        await start()
        let request: (id: String, parameters: [String: JSONValue])
        do {
            request = try SwitchboardURL.parse(url)
        } catch {
            let message = Self.describe(error)
            record(.error, "URL \(url.absoluteString): \(message)")
            await notify("Cannot open \(url.absoluteString): \(message)")
            return nil
        }
        record(.info, "URL \(url.absoluteString): run \(request.id)")
        let outcome = await run(id: request.id, parameters: request.parameters)
        record(outcome.succeeded ? .info : .error, "URL run \(request.id): \(outcome.status) (\(outcome.message))")
        if !outcome.succeeded {
            await notify("\(request.id) did not run: \(outcome.message)")
        }
        return outcome
    }

    // MARK: Settings

    /// Writes `settings.json` and takes the new settings. A change to anything the runtime is
    /// built from (controller address, display name, polling interval, API port) rebuilds it; the
    /// log and the last reading carry over. During a run the rebuild waits for the run to end.
    /// Throws `SettingsError` when the file cannot be written.
    public func saveSettings(_ new: Settings) async throws {
        try await settingsStore.save(new)
        let old = settings
        settings = new
        record(.info, "settings saved")
        guard Self.needsNewRuntime(from: old, to: new) else { return }
        if isBusy {
            pendingRebuild = true
            record(.info, "the new settings apply when the run in progress ends")
        } else {
            rebuildRuntime()
        }
    }

    private static func needsNewRuntime(from old: Settings, to new: Settings) -> Bool {
        old.controllerURL != new.controllerURL
            || old.displayNameContains != new.displayNameContains
            || old.pollingIntervalSeconds != new.pollingIntervalSeconds
            || old.localAPIPort != new.localAPIPort
            || old.displaysToTurnOff != new.displaysToTurnOff
    }

    private func applyPendingRebuild() {
        guard pendingRebuild else { return }
        pendingRebuild = false
        rebuildRuntime()
    }

    private func rebuildRuntime() {
        runtime.refresher.stop()
        let next = runtimeFactory(settings, store, notifyAction)
        runtime = next
        // The old controller's last answer says nothing about the new address (or about none).
        if next.controller == nil, store.state.controllerReachable {
            store.setControllerReachable(false)
        }
        if isStarted {
            next.refresher.start()
            startServices()
            record(.info, "settings applied; controller \(next.controllerURL?.absoluteString ?? "none"), display \"\(settings.displayNameContains)\"")
        }
    }

    /// The first controller that answers over mDNS (`_switchboard._tcp`), for the Settings window to
    /// offer. Does not change any setting.
    public func discoverController(timeout: Duration = .seconds(3)) async -> DiscoveredController? {
        record(.info, "looking for a controller over mDNS")
        let found = await discovery(timeout)
        if let found {
            record(.info, "found controller \"\(found.name)\" at \(found.url.absoluteString)")
        } else {
            record(.warning, "no controller found over mDNS (is the Local Network permission granted?)")
        }
        return found
    }

    // MARK: Launch at login

    /// Registers or unregisters the app as a login item (`SMAppService.mainApp`) and remembers what
    /// macOS says. The returned text (also in `launchAtLoginMessage`) is nil when all is well; it
    /// says so when approval is pending in System Settings, when the call failed, and when the app
    /// is not running from the `.app` bundle, where the call cannot work.
    @discardableResult
    public func setLaunchAtLogin(_ enabled: Bool) async -> String? {
        var message: String?
        let before = loginItem.status
        if before == .notInBundle {
            message = LaunchAtLoginError.notInBundle.description
        } else if enabled != before.isOn {
            do {
                if enabled { try loginItem.register() } else { try loginItem.unregister() }
            } catch {
                message = "Could not turn launch at login \(enabled ? "on" : "off"): \(Self.describe(error))"
            }
        }

        let after = loginItem.status
        launchAtLoginStatus = after
        if message == nil {
            switch after {
            case .requiresApproval:
                message = "Approve Switchboard in System Settings > General > Login Items to finish turning this on."
            case .notFound:
                message = "macOS cannot find Switchboard as a login item. Move Switchboard.app to Applications and open it from there."
            default:
                break
            }
        }
        launchAtLoginMessage = message
        if let message { record(.warning, "launch at login: \(message)") } else { record(.info, "launch at login \(after.isOn ? "on" : "off")") }

        // Keep settings.json in step with what the system now says (not when there is no bundle to ask).
        if after != .notInBundle, settings.launchAtLogin != after.isOn {
            var updated = settings
            updated.launchAtLogin = after.isOn
            do {
                try await settingsStore.save(updated)
                settings = updated
            } catch {
                record(.error, "settings: \(Self.describe(error))")
            }
        }
        return message
    }

    /// Opens System Settings > General > Login Items, where a pending approval is granted.
    public func openLoginItemsSettings() {
        loginItem.openSystemSettings()
    }

    // MARK: Macros

    /// Reads `macros.json` again (writing the defaults when there is none). A file that cannot be
    /// read leaves the list empty and `macrosError` set; the file is not touched.
    public func reloadMacros() async {
        do {
            macros = try await runtime.macros.load()
            macrosError = nil
        } catch {
            macros = []
            macrosError = Self.describe(error)
            record(.error, "macros: \(Self.describe(error))")
        }
    }

    /// Validates and writes the macros (`MacroStore.save`) and takes them as the list. Throws
    /// `MacroStoreError` (the message names the macro and the step) and writes nothing when they are
    /// not valid.
    public func saveMacros(_ new: [Macro]) async throws {
        try await runtime.macros.save(new)
        macros = new
        macrosError = nil
        record(.info, "saved \(new.count) macro\(new.count == 1 ? "" : "s")")
    }

    // MARK: Notifications

    /// Shows a user notification when the system allows it, otherwise writes the text to the log.
    public func notify(_ text: String) async {
        await notifyAction(text)
    }

    private nonisolated static func makeNotify(notifier: any UserNotifier, store: StateStore) -> @Sendable (String) async -> Void {
        { text in
            if case .skipped(let reason) = await notifier.post(title: "Switchboard", body: text) {
                await store.log(.info, "notification not shown (\(reason)): \(text)")
            }
        }
    }

    // MARK: Logging

    /// To the in-app log (`runtime.store.log`) and to `os.Logger` (subsystem
    /// `io.github.fgiannazzo.switchboard`, so `log stream` sees it too).
    private func record(_ level: LogEntry.Level, _ message: String) {
        store.log(level, message)
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }

    private nonisolated static func describe(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
