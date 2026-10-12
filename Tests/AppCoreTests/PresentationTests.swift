import AppCore
import Foundation
import StateStore
import SwitchboardCore
import Testing

@Suite("SettingsDraft")
struct SettingsDraftTests {
    @Test("a draft shows the settings as the CLI prints them")
    func fromSettings() {
        let draft = SettingsDraft(Settings(controllerURL: URL(string: "http://192.168.1.50:80"), displayNameContains: "DualUp", pollingIntervalSeconds: 12, localAPIPort: 48601))
        #expect(draft.controllerURL == "http://192.168.1.50:80")
        #expect(draft.displayNameContains == "DualUp")
        #expect(draft.pollingIntervalSeconds == "12")
        #expect(draft.localAPIPort == "48601")
        #expect(SettingsDraft(Settings()).controllerURL == "")
    }

    @Test("converting back applies every field and keeps launchAtLogin")
    func toSettings() throws {
        var draft = SettingsDraft(Settings())
        draft.controllerURL = "192.168.1.60:8080"
        draft.displayNameContains = " Foo "
        draft.pollingIntervalSeconds = "5"
        draft.localAPIPort = "49000"
        let base = Settings(launchAtLogin: true)

        let result = try draft.settings(applyingTo: base)
        #expect(result.controllerURL?.absoluteString == "http://192.168.1.60:8080")
        #expect(result.displayNameContains == "Foo")
        #expect(result.pollingIntervalSeconds == 5)
        #expect(result.localAPIPort == 49000)
        #expect(result.launchAtLogin)
    }

    @Test("an empty controller address clears it")
    func clearController() throws {
        var draft = SettingsDraft(Settings(controllerURL: URL(string: "http://x:1")))
        draft.controllerURL = ""
        #expect(try draft.settings(applyingTo: Settings(controllerURL: URL(string: "http://x:1"))).controllerURL == nil)
    }

    @Test("the CLI's rules apply: each bad field is refused with its own message")
    func refusals() {
        func message(_ change: (inout SettingsDraft) -> Void) -> String? {
            var draft = SettingsDraft(Settings())
            change(&draft)
            do {
                _ = try draft.settings(applyingTo: Settings())
                return nil
            } catch {
                return "\(error)"
            }
        }
        #expect(message { $0.controllerURL = "ftp://x" }?.contains("not a controller address") == true)
        #expect(message { $0.displayNameContains = "  " }?.contains("must not be empty") == true)
        #expect(message { $0.pollingIntervalSeconds = "0" }?.contains("1 to 3600") == true)
        #expect(message { $0.pollingIntervalSeconds = "soon" }?.contains("1 to 3600") == true)
        #expect(message { $0.localAPIPort = "70000" }?.contains("1 to 65535") == true)
        #expect(message { _ in } == nil)
    }
}

@Suite("Log and state presentation")
struct PresentationTests {
    private func entry(_ level: LogEntry.Level, _ message: String, at seconds: TimeInterval = 0) -> LogEntry {
        LogEntry(date: Date(timeIntervalSince1970: 1_800_000_000 + seconds), level: level, message: message)
    }

    private var log: [LogEntry] {
        [
            entry(.debug, "d", at: 0),
            entry(.info, "i", at: 1),
            entry(.warning, "w", at: 2),
            entry(.error, "e", at: 3),
        ]
    }

    @Test("the window lists newest first")
    func newestFirst() {
        #expect(LogPresentation.entries(log, minimum: nil).map(\.message) == ["e", "w", "i", "d"])
    }

    @Test("the level filter keeps that level and above")
    func levelFilter() {
        #expect(LogPresentation.entries(log, minimum: .info).map(\.message) == ["e", "w", "i"])
        #expect(LogPresentation.entries(log, minimum: .warning).map(\.message) == ["e", "w"])
        #expect(LogPresentation.entries(log, minimum: .error).map(\.message) == ["e"])
        #expect(LogPresentation.entries([], minimum: .error).isEmpty)
    }

    @Test("Copy all writes every entry, oldest first, one line each")
    func copyText() {
        let text = LogPresentation.text(log)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines[0].hasSuffix(" debug d"))
        #expect(lines[3].hasSuffix(" error e"))
        #expect(lines[0].hasPrefix("2027-"), "an ISO 8601 timestamp: \(lines[0])")
        #expect(LogPresentation.text([]) == "")
    }

    @Test("relative time")
    func relativeTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func text(_ secondsAgo: TimeInterval) -> String { RelativeTime.text(for: now.addingTimeInterval(-secondsAgo), now: now) }
        #expect(RelativeTime.text(for: .distantPast, now: now) == "never")
        #expect(text(0) == "just now")
        #expect(text(4) == "just now")
        #expect(text(-30) == "just now", "a clock a little ahead is not a date in the future")
        #expect(text(5) == "5 s ago")
        #expect(text(59) == "59 s ago")
        #expect(text(60) == "1 min ago")
        #expect(text(3599) == "59 min ago")
        #expect(text(3600) == "1 h ago")
        #expect(text(86_399) == "23 h ago")
        #expect(text(86_400 * 3) == "3 d ago")
    }

    @Test("state wording")
    func titles() {
        #expect(DisplayID.dualup.title == "DualUp")
        #expect(DisplayID.lg4k.title == "LG 4K")
        #expect(DisplayID.samsung.title == "Samsung")
        #expect(PBPState.on.title == "On")
        #expect(PBPState.unknown.title == "Unknown")
        #expect(MainInput.hdmi2.title == "HDMI 2")
        let state = SwitchboardState(usbPort: 3, hdmiInput: [.lg4k: 2])
        #expect(state.usbPortTitle == "Port 3")
        #expect(SwitchboardState().usbPortTitle == "Unknown")
        #expect(state.hdmiInputTitle(for: .lg4k) == "HDMI 2")
        #expect(state.hdmiInputTitle(for: .samsung) == nil)
    }
}
