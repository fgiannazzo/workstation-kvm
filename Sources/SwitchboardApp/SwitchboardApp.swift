import AppCore
import SwiftUI

/// The ids of the windows the popover opens.
enum WindowID {
    static let macros = "macros"
    static let settings = "settings"
    static let log = "log"
}

/// The one model, shared by the scenes and the application delegate (which receives
/// `switchboard://` URLs outside of any view).
@MainActor
enum AppEnvironment {
    static let model = AppModel()
}

/// The menu bar app: a status item whose glyph is the monitor's state, a popover with the state and
/// the controls, and three windows (macro editor, settings, log) that the popover opens. No
/// windows appear at launch and there is no Dock icon (`LSUIElement`).
@main
struct SwitchboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: AppEnvironment.model)
        } label: {
            MenuBarLabel(model: AppEnvironment.model)
        }
        .menuBarExtraStyle(.window)
        .handlesExternalEvents(matching: [])

        Window("Macros", id: WindowID.macros) {
            MacroEditorView(model: AppEnvironment.model)
        }
        .defaultLaunchBehavior(.suppressed)
        .handlesExternalEvents(matching: [])

        Window("Settings", id: WindowID.settings) {
            SettingsView(model: AppEnvironment.model)
        }
        .defaultLaunchBehavior(.suppressed)
        .handlesExternalEvents(matching: [])
        .windowResizability(.contentSize)

        Window("Log", id: WindowID.log) {
            LogView(model: AppEnvironment.model)
        }
        .defaultLaunchBehavior(.suppressed)
        .handlesExternalEvents(matching: [])
    }
}

/// Starts the model when the app has launched and hands `switchboard://` URLs to it. The URL
/// scheme is declared in `App/Info.plist`; macOS delivers `switchboard://run/{id}` here, whether the
/// app was running or is launched by the URL.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await AppEnvironment.model.start() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == SwitchboardURL.scheme {
            Task { await AppEnvironment.model.handle(url: url) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppEnvironment.model.stop()
    }
}

/// Brings a window forward: a menu bar app is not the active application, so a window it opens
/// would otherwise appear behind the others.
@MainActor
func showWindow(_ id: String, using openWindow: OpenWindowAction) {
    openWindow(id: id)
    NSApplication.shared.activate()
}
