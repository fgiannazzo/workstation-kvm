import Actions
import AppCore
import DDCKit
import Devices
import ESP32Kit
import Foundation
import StateStore
import SwitchboardCore
import Testing

@MainActor
@Suite("AppModel")
struct AppModelTests {
    // MARK: Start

    @Test("a fresh model touches nothing: no files, no polling, nothing known")
    func fresh() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            #expect(rig.model.state == SwitchboardState())
            #expect(rig.model.macros.isEmpty)
            #expect(!rig.model.runtime.refresher.isRunning)
            #expect(!rig.model.isBusy)
            #expect(rig.model.runProgress == RunProgress())
            #expect(rig.model.actions.count == 8)
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }

    @Test("start loads the default macros, creates macros.json and starts the refresher")
    func startLoadsDefaults() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            await rig.model.start()
            defer { rig.model.stop() }

            #expect(rig.model.macros.map(\.id) == ["guest", "solo"])
            #expect(rig.model.macrosError == nil)
            #expect(FileManager.default.fileExists(atPath: directory.appending(path: "macros.json").path))
            #expect(rig.model.runtime.refresher.isRunning)
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "settings.json").path), "start does not write settings")

            // The refresher's first poll is a read: PBP off, HDMI 1, controller on USB port 1.
            await waitUntil("the first poll") { rig.model.state.dualUpReachable && rig.model.state.controllerReachable }
            #expect(rig.model.state.pbp == .off)
            #expect(rig.model.state.mainInput == .hdmi1)
            #expect(rig.model.state.usbPort == 1)
            #expect(rig.model.state.hdmiInput == [.dualup: 1, .lg4k: 1, .samsung: 1])
            #expect(await rig.bridge.writes.isEmpty, "polling never writes to the monitor")
            let calls = await rig.controller.calls
            #expect(calls.allSatisfy { $0 == "state" }, "polling only reads the controller: \(calls)")
        }
    }

    @Test("start is idempotent: a second call neither restarts nor reloads")
    func startTwice() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            await rig.model.start()
            defer { rig.model.stop() }
            await rig.model.start()
            #expect(rig.builtWith.all.count == 1, "no settings file: the runtime built in init is kept")
            #expect(rig.model.runtime.refresher.isRunning)
        }
    }

    @Test("start takes settings.json and rebuilds the runtime from it")
    func startLoadsSettings() async throws {
        try await withTempDirectory { directory in
            try await SettingsStore(directory: directory).save(Settings(displayNameContains: "Other", pollingIntervalSeconds: 5))
            let rig = ModelRig(directory: directory)
            await rig.model.start()
            defer { rig.model.stop() }

            #expect(rig.model.settings.displayNameContains == "Other")
            #expect(rig.builtWith.all.map(\.displayNameContains) == ["SDQHD", "Other"])
            #expect(rig.model.runtime.settings.pollingIntervalSeconds == 5)
        }
    }

    @Test("a settings.json that cannot be read leaves the defaults, says so, and is not touched")
    func brokenSettings() async throws {
        try await withTempDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: "settings.json")
            try Data(#"{"localAPIPort": "not a number"}"#.utf8).write(to: file)

            let rig = ModelRig(directory: directory)
            await rig.model.start()
            defer { rig.model.stop() }

            #expect(rig.model.settings == Settings())
            #expect(rig.model.startupError?.contains("settings.json") == true)
            #expect(logMessages(rig.model).contains { $0.hasPrefix("settings:") })
            #expect(try String(contentsOf: file, encoding: .utf8) == #"{"localAPIPort": "not a number"}"#)
        }
    }

    @Test("a macros.json that cannot be loaded leaves no macros, says why, and is not overwritten")
    func brokenMacros() async throws {
        try await withTempDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: "macros.json")
            try Data(#"{"macros": [{"id": "x", "name": "X", "steps": []}]}"#.utf8).write(to: file)

            let rig = ModelRig(directory: directory)
            await rig.model.start()
            defer { rig.model.stop() }

            #expect(rig.model.macros.isEmpty)
            #expect(rig.model.macrosError?.contains("has no steps") == true)
            #expect(try String(contentsOf: file, encoding: .utf8) == #"{"macros": [{"id": "x", "name": "X", "steps": []}]}"#)

            // Once the file is fixed by hand, reloading picks it up.
            try Data(#"{"macros": [{"id": "x", "name": "X", "steps": [{"action": "monitor.read"}]}]}"#.utf8).write(to: file)
            await rig.model.reloadMacros()
            #expect(rig.model.macros.map(\.id) == ["x"])
            #expect(rig.model.macrosError == nil)
        }
    }

    // MARK: Running

    @Test("running usb.select with port 2 moves the controller, updates the state and the progress")
    func runUSBSelect() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            await rig.model.start()
            defer { rig.model.stop() }

            let outcome = await rig.model.run(id: "usb.select", parameters: ["port": 2])

            #expect(outcome.status == .finished)
            #expect(outcome.succeeded)
            #expect(outcome.message == "ok")
            #expect(rig.model.state.usbPort == 2)
            #expect(await rig.controller.calls.contains("selectUSB(2)"))

            let progress = rig.model.runProgress
            #expect(progress.id == "usb.select")
            #expect(!progress.isRunning)
            #expect(progress.lastOutcome == .finished)
            #expect(progress.stepCount == 1)
            #expect(progress.currentStep == 1)
            #expect(progress.lastMessage == "ok")
            #expect(progress.statusLine == "Finished usb.select")
            #expect(!rig.model.isBusy)
            #expect(logMessages(rig.model).contains { $0.contains("run usb.select finished") })
        }
    }

    @Test("running a macro: PBP on goes out over the USB bridge, is read back, then the USB port moves")
    func runGuest() async throws {
        try await withTempDirectory { directory in
            // The cable reads 0xD7 = 0, as it does once the monitor has taken the bridge's write.
            let rig = ModelRig(directory: directory, pbp: 0)
            await rig.model.start()
            defer { rig.model.stop() }

            let outcome = await rig.model.run(id: "guest")

            #expect(outcome.succeeded)
            #expect(rig.model.state.pbp == .on)
            #expect(rig.model.state.usbPort == 2)
            let writes = await rig.bridge.writes
            #expect(writes.count == 1)
            #expect(writes.first?.code == 0xD7)
            #expect(writes.first?.value == 0)
            #expect(await rig.cable.writes.isEmpty, "PBP on is never written on the video cable")
            #expect(rig.model.runProgress.stepCount == 2)
            #expect(rig.model.runProgress.lastOutcome == .finished)
        }
    }

    @Test("a monitor write that is not confirmed fails the run and the progress says where")
    func runUnverified() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory, pbp: 1)   // the cable keeps reading "off"
            await rig.model.start()
            defer { rig.model.stop() }

            let outcome = await rig.model.run(id: "guest")

            #expect(outcome.status == .failed)
            #expect(outcome.message.contains("unverified"))
            #expect(rig.model.runProgress.lastOutcome == .failed)
            #expect(rig.model.runProgress.currentStep == 1)
            #expect(rig.model.runProgress.statusLine.hasPrefix("Failed guest: monitor.pbp.on: unverified"))
            #expect(rig.model.state.lastError?.hasPrefix("guest:") == true)
            #expect(!(await rig.controller.calls.contains("selectUSB(2)")), "the macro stopped before usb.select")
        }
    }

    @Test("a controller that does not answer fails the run, and the glyph turns red")
    func runControllerDown() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            await rig.controller.fail(with: .timeout)
            await rig.model.start()
            defer { rig.model.stop() }

            let outcome = await rig.model.run(id: "usb.select", parameters: ["port": 3])

            #expect(outcome.status == .failed)
            #expect(rig.model.runProgress.lastOutcome == .failed)
            #expect(rig.model.state.lastError != nil)
            #expect(StatusGlyph.symbol(for: rig.model.state).tint == .red)
        }
    }

    @Test("an unknown id or a bad parameter is rejected without starting a run")
    func rejected() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            await rig.model.start()
            defer { rig.model.stop() }

            let unknown = await rig.model.run(id: "nope")
            #expect(unknown.status == .rejected)
            #expect(unknown.message == "unknown action or macro \"nope\"")
            #expect(rig.model.runProgress.lastOutcome == .failed)
            #expect(rig.model.runProgress.statusLine == "Failed nope: unknown action or macro \"nope\"")

            let outOfRange = await rig.model.run(id: "usb.select", parameters: ["port": 9])
            #expect(outOfRange.status == .rejected)
            #expect(outOfRange.message.contains("must be 1 to 4"))

            let missing = await rig.model.run(id: "usb.select")
            #expect(missing.message == "missing parameter \"port\"")

            #expect(await rig.controller.calls.filter { $0 != "state" }.isEmpty, "nothing reached the controller")
            #expect(!rig.model.isBusy)
        }
    }

    @Test("while a run is in progress the model is busy, a second run is refused, and the first finishes")
    func busy() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            let gate = Gate()
            await rig.controller.hold(at: gate)
            await rig.model.start()
            defer { rig.model.stop() }

            let first = Task { await rig.model.run(id: "usb.select", parameters: ["port": 2]) }
            await waitUntil("the run to be at the controller") { rig.model.runProgress.isRunning && rig.model.isBusy }
            #expect(rig.model.runProgress.statusLine == "Running usb.select, step 1 of 1")

            let second = await rig.model.run(id: "usb.select", parameters: ["port": 3])
            #expect(second.status == .rejected)
            #expect(second.message == "another run is in progress")
            #expect(rig.model.runProgress.isRunning, "the refused request leaves the progress of the first alone")

            await gate.release()
            let outcome = await first.value
            #expect(outcome.succeeded)
            #expect(!rig.model.isBusy)
            #expect(rig.model.state.usbPort == 2)
            #expect(await rig.controller.calls.filter { $0.hasPrefix("selectUSB") } == ["selectUSB(2)"])
        }
    }

    // MARK: The OREI correction

    @Test("resyncHDMI runs hdmi.resync: the controller is told, nothing is pulsed")
    func resync() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            await rig.model.start()
            defer { rig.model.stop() }

            let outcome = await rig.model.resyncHDMI(display: .lg4k, input: 2)

            #expect(outcome.succeeded)
            let calls = await rig.controller.calls
            #expect(calls.contains("resyncHDMI(lg4k, 2)"))
            #expect(!calls.contains { $0.hasPrefix("selectHDMI") })
            #expect(rig.model.state.hdmiInput[.lg4k] == 2)
            #expect(rig.model.state.hdmiInput[.dualup] == 1)
            #expect(rig.model.runProgress.id == "hdmi.resync")
            #expect(rig.model.runProgress.lastOutcome == .finished)
        }
    }

    // MARK: Settings

    @Test("saveSettings writes settings.json and rebuilds the runtime when the controller address changes")
    func saveSettings() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            await rig.model.start()
            defer { rig.model.stop() }
            #expect(rig.builtWith.all.count == 1)

            var changed = rig.model.settings
            changed.controllerURL = URL(string: "http://192.168.1.77:80")
            changed.displayNameContains = "DualUp"
            try await rig.model.saveSettings(changed)

            #expect(rig.model.settings == changed)
            let saved = try await SettingsStore(directory: directory).load()
            #expect(saved == changed)
            #expect(rig.builtWith.all.count == 2)
            #expect(rig.builtWith.all.last == changed)
            #expect(rig.model.runtime.settings == changed)
            #expect(rig.model.controllerURL?.absoluteString == "http://192.168.1.77:80")
            #expect(rig.model.runtime.refresher.isRunning, "the new runtime polls too")
            #expect(logMessages(rig.model).contains("settings saved"))
        }
    }

    @Test("a rebuilt runtime keeps the log and the last reading")
    func rebuildKeepsHistory() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            await rig.model.start()
            defer { rig.model.stop() }
            await rig.model.run(id: "usb.select", parameters: ["port": 2])
            let logBefore = rig.model.log.count
            #expect(logBefore > 0)

            var changed = rig.model.settings
            changed.pollingIntervalSeconds = 10
            try await rig.model.saveSettings(changed)

            #expect(rig.builtWith.all.count == 2)
            #expect(rig.model.log.count >= logBefore)
            #expect(logMessages(rig.model).contains { $0.contains("run usb.select finished") })
            #expect(rig.model.state.usbPort == 2)
        }
    }

    @Test("a rebuilt runtime that has no controller marks the controller unreachable")
    func runtimeWithoutController() async throws {
        try await withTempDirectory { directory in
            let model = AppModel(
                environment: [:],
                supportDirectory: directory,
                runtimeFactory: { settings, store, notify in
                    Runtime(
                        settings: settings, controllerURL: nil,
                        dualUp: LGDualUp(videoCable: FakeDDC(), usbBridge: FakeDDC(supportsRead: false), sleep: instant),
                        controller: nil, appSupport: directory, notify: notify, store: store
                    )
                },
                notifier: FakeNotifier(),
                loginItem: FakeLoginItem()
            )
            // The old controller had answered; the new address (or none) says nothing about it.
            model.runtime.store.apply(FakeController.initialState)
            #expect(model.state.controllerReachable)

            var settings = model.settings
            settings.controllerURL = URL(string: "http://elsewhere:1")
            try await model.saveSettings(settings)

            #expect(!model.state.controllerReachable)
        }
    }

    @Test("a change that the runtime is not built from (launch at login) does not rebuild it")
    func launchAtLoginDoesNotRebuild() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            await rig.model.start()
            defer { rig.model.stop() }

            var changed = rig.model.settings
            changed.launchAtLogin = true
            try await rig.model.saveSettings(changed)

            #expect(rig.builtWith.all.count == 1)
            let saved = try await SettingsStore(directory: directory).load()
            #expect(saved.launchAtLogin)
        }
    }

    @Test("settings saved during a run apply when the run ends, and the run is not disturbed")
    func saveDuringRun() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            let gate = Gate()
            await rig.controller.hold(at: gate)
            await rig.model.start()
            defer { rig.model.stop() }

            let run = Task { await rig.model.run(id: "usb.select", parameters: ["port": 2]) }
            await waitUntil("the run to be going") { rig.model.isBusy }

            var changed = rig.model.settings
            changed.controllerURL = URL(string: "http://192.168.1.88:80")
            try await rig.model.saveSettings(changed)
            let saved = try await SettingsStore(directory: directory).load()
            #expect(saved == changed, "saved at once")
            #expect(rig.builtWith.all.count == 1, "but not applied while the run holds the runner")

            await gate.release()
            #expect(await run.value.succeeded)
            #expect(rig.builtWith.all.count == 2)
            #expect(rig.model.runtime.settings == changed)
        }
    }

    // MARK: Macros

    @Test("saveMacros validates, writes macros.json and takes the macros")
    func saveMacros() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            await rig.model.start()
            defer { rig.model.stop() }

            let test = Macro(id: "test", name: "Test", steps: [MacroStep(action: .delay, parameters: ["ms": 10])])
            try await rig.model.saveMacros(rig.model.macros + [test])

            #expect(rig.model.macros.map(\.id) == ["guest", "solo", "test"])
            let onDisk = try await MacroStore(directory: directory).load()
            #expect(onDisk.map(\.id) == ["guest", "solo", "test"])

            let outcome = await rig.model.run(id: "test")
            #expect(outcome.succeeded, "a saved macro runs")
        }
    }

    @Test("saveMacros refuses invalid macros, says why, and leaves the file as it was")
    func saveInvalidMacros() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            await rig.model.start()
            defer { rig.model.stop() }
            let before = try Data(contentsOf: directory.appending(path: "macros.json"))

            let bad = Macro(id: "bad", name: "Bad", steps: [MacroStep(action: .usbSelect, parameters: ["port": 9])])
            do {
                try await rig.model.saveMacros([bad])
                Issue.record("saveMacros accepted a port of 9")
            } catch let error as MacroStoreError {
                #expect("\(error)".contains("must be 1 to 4"))
            }

            #expect(rig.model.macros.map(\.id) == ["guest", "solo"])
            #expect(try Data(contentsOf: directory.appending(path: "macros.json")) == before)
        }
    }

    // MARK: Launch at login

    @Test("turning launch at login on registers the app and remembers it in settings.json")
    func launchAtLoginOn() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            await rig.model.start()
            defer { rig.model.stop() }

            let message = await rig.model.setLaunchAtLogin(true)

            #expect(message == nil)
            #expect(rig.loginItem.calls == ["register"])
            #expect(rig.model.launchAtLoginStatus == .enabled)
            #expect(rig.model.launchAtLoginMessage == nil)
            #expect(rig.model.settings.launchAtLogin)
            let saved = try await SettingsStore(directory: directory).load()
            #expect(saved.launchAtLogin)

            #expect(await rig.model.setLaunchAtLogin(false) == nil)
            #expect(rig.loginItem.calls == ["register", "unregister"])
            #expect(rig.model.launchAtLoginStatus == .notRegistered)
            #expect(!rig.model.settings.launchAtLogin)
        }
    }

    @Test("when macOS wants the user to approve it, the message says where")
    func launchAtLoginNeedsApproval() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            rig.loginItem.registering(becomes: .requiresApproval)
            await rig.model.start()
            defer { rig.model.stop() }

            let message = await rig.model.setLaunchAtLogin(true)

            #expect(message?.contains("System Settings > General > Login Items") == true)
            #expect(rig.model.launchAtLoginStatus == .requiresApproval)
            #expect(rig.model.launchAtLoginStatus.isOn, "the toggle stays on while approval is pending")
            #expect(rig.model.launchAtLoginMessage == message)
            rig.model.openLoginItemsSettings()
            #expect(rig.loginItem.calls.contains("openSystemSettings"))
        }
    }

    @Test("an error from the system is reported and settings.json is not changed")
    func launchAtLoginError() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            rig.loginItem.fail(with: "Operation not permitted")
            await rig.model.start()
            defer { rig.model.stop() }

            let message = await rig.model.setLaunchAtLogin(true)

            #expect(message == "Could not turn launch at login on: Operation not permitted")
            #expect(rig.model.launchAtLoginStatus == .notRegistered)
            #expect(!rig.model.settings.launchAtLogin)
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "settings.json").path))
        }
    }

    @Test("outside an app bundle it says to run the .app and calls nothing")
    func launchAtLoginNoBundle() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory, loginStatus: .notInBundle)
            await rig.model.start()
            defer { rig.model.stop() }

            let message = await rig.model.setLaunchAtLogin(true)

            #expect(message?.contains("make app") == true)
            #expect(message?.contains("Switchboard.app") == true)
            #expect(rig.loginItem.calls.isEmpty)
            #expect(rig.model.launchAtLoginStatus == .notInBundle)
            #expect(!rig.model.settings.launchAtLogin)
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "settings.json").path))
        }
    }

    @Test("asking for what is already so does not call the system")
    func launchAtLoginNoop() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory, loginStatus: .enabled)
            await rig.model.start()
            defer { rig.model.stop() }

            #expect(await rig.model.setLaunchAtLogin(true) == nil)
            #expect(rig.loginItem.calls.isEmpty)
        }
    }

    // MARK: Notifications

    @Test("notify shows a notification when the system allows it")
    func notifyPosts() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            await rig.model.notify("Guest mode")
            #expect(rig.notifier.bodies == ["Guest mode"])
            #expect(rig.model.log.isEmpty)
        }
    }

    @Test("notify logs the text when no notification can be shown")
    func notifyLogs() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            rig.notifier.answer(with: .skipped("notifications are not allowed"))
            await rig.model.notify("Guest mode")
            #expect(logMessages(rig.model) == ["notification not shown (notifications are not allowed): Guest mode"])
        }
    }

    @Test("the notify action goes through the same path")
    func notifyAction() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            await rig.model.start()
            defer { rig.model.stop() }
            let outcome = await rig.model.run(.notify, parameters: ["text": "Hello"])
            #expect(outcome.succeeded)
            #expect(rig.notifier.bodies == ["Hello"])
        }
    }

    // MARK: Discovery

    @Test("discoverController returns what mDNS finds, for the Settings window to offer")
    func discovery() async throws {
        try await withTempDirectory { directory in
            let url = try #require(URL(string: "http://192.168.1.50:80"))
            let found = DiscoveredController(name: "Switchboard ESP32", host: "192.168.1.50", port: 80, url: url)
            let rig = ModelRig(directory: directory, found: found)

            let result = await rig.model.discoverController(timeout: .seconds(1))

            #expect(result == found)
            #expect(rig.discovered.all == [.seconds(1)])
            #expect(rig.model.settings.controllerURL == nil, "discovery does not change any setting")
            #expect(logMessages(rig.model).contains { $0.contains("found controller \"Switchboard ESP32\"") })
        }
    }

    @Test("discoverController is nil, and says so in the log, when nothing answers")
    func discoveryFindsNothing() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            #expect(await rig.model.discoverController() == nil)
            #expect(logMessages(rig.model).contains { $0.contains("no controller found") })
        }
    }

    // MARK: URL scheme

    @Test("a switchboard:// URL runs an action with its parameters")
    func urlRunsAction() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            defer { rig.model.stop() }

            let outcome = await rig.model.handle(url: try #require(URL(string: "switchboard://run/usb.select?port=3")))

            #expect(outcome?.succeeded == true)
            #expect(rig.model.state.usbPort == 3)
            #expect(rig.model.runProgress.lastOutcome == .finished)
            #expect(rig.model.macros.map(\.id) == ["guest", "solo"], "handling a URL starts the model first")
            #expect(rig.notifier.bodies.isEmpty, "a run that works is quiet")
        }
    }

    @Test("a switchboard:// URL runs a macro")
    func urlRunsMacro() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            defer { rig.model.stop() }

            let outcome = await rig.model.handle(url: try #require(URL(string: "switchboard://run/solo")))

            // solo: usb.select 1, then PBP off over the video cable (verified by the fake's read).
            #expect(outcome?.succeeded == true)
            #expect(rig.model.runProgress.id == "solo")
            #expect(rig.model.state.pbp == .off)
            #expect(rig.model.state.usbPort == 1)
        }
    }

    @Test("a URL that does not parse is logged and shown, and runs nothing")
    func urlBad() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            defer { rig.model.stop() }

            let outcome = await rig.model.handle(url: try #require(URL(string: "switchboard://state/solo")))

            #expect(outcome == nil)
            #expect(rig.notifier.bodies.count == 1)
            #expect(rig.notifier.bodies.first?.contains("switchboard://run/{id}") == true)
            #expect(logMessages(rig.model).contains { $0.contains("switchboard://state/solo") })
            #expect(rig.model.runProgress == RunProgress())
        }
    }

    @Test("a run that fails through a URL is shown as a notification")
    func urlFailingRun() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            defer { rig.model.stop() }

            let outcome = await rig.model.handle(url: try #require(URL(string: "switchboard://run/usb.select?port=abc")))

            #expect(outcome?.status == .rejected)
            #expect(rig.notifier.bodies.count == 1)
            #expect(rig.notifier.bodies.first?.hasPrefix("usb.select did not run: invalid parameter \"port\"") == true)
            #expect(await rig.controller.calls.filter { $0 != "state" }.isEmpty)
        }
    }

    @Test("an unknown id through a URL is a notification, not a crash")
    func urlUnknownID() async throws {
        try await withTempDirectory { directory in
            let rig = ModelRig(directory: directory)
            defer { rig.model.stop() }

            let outcome = await rig.model.handle(url: try #require(URL(string: "switchboard://run/nope")))

            #expect(outcome?.status == .rejected)
            #expect(rig.notifier.bodies == ["nope did not run: unknown action or macro \"nope\""])
        }
    }

    // MARK: Environment

    @Test("the support directory and the controller override come from the environment")
    func environment() async throws {
        let model = AppModel(
            environment: ["SWITCHBOARD_SUPPORT_DIR": "/tmp/switchboard-env-test", "SWITCHBOARD_CONTROLLER_URL": "http://10.0.0.9:80"],
            notifier: FakeNotifier(),
            loginItem: FakeLoginItem()
        )
        #expect(model.supportDirectory.path(percentEncoded: false).hasPrefix("/tmp/switchboard-env-test"))
        #expect(model.controllerURL?.absoluteString == "http://10.0.0.9:80")
        #expect(model.controllerURLComesFromEnvironment)
        #expect(model.runtime.dualUp.videoCable.name == "video cable (SDQHD)")
        #expect(!model.runtime.refresher.isRunning, "Runtime.live starts nothing")
    }
}
