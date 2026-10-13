import Foundation
import StateStore
import Testing

/// A fresh directory that is removed afterwards. The directory itself is not created.
func withTempDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory.appending(path: "switchboard-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

@Suite("Settings")
struct SettingsTests {
    @Test("defaults are the ones in the brief")
    func defaults() {
        let settings = Settings()
        #expect(settings.controllerURL == nil)
        #expect(settings.displayNameContains == "SDQHD")
        #expect(settings.pollingIntervalSeconds == 30)
        #expect(settings.localAPIPort == 48600)
        #expect(settings.launchAtLogin == false)
    }

    @Test("a settings value round-trips through JSON")
    func roundTrip() throws {
        let settings = Settings(
            controllerURL: URL(string: "http://192.168.1.50:80"),
            displayNameContains: "DualUp",
            pollingIntervalSeconds: 12.5,
            localAPIPort: 49000,
            launchAtLogin: true
        )
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(Settings.self, from: data) == settings)
    }

    @Test("an empty object decodes to the defaults, and missing keys fall back one by one")
    func partialDecode() throws {
        #expect(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)) == Settings())

        let partial = try JSONDecoder().decode(Settings.self, from: Data(#"{"localAPIPort": 50000, "launchAtLogin": true}"#.utf8))
        #expect(partial.localAPIPort == 50000)
        #expect(partial.launchAtLogin == true)
        #expect(partial.displayNameContains == "SDQHD")
        #expect(partial.pollingIntervalSeconds == 30)
    }

    @Test("a controller URL that is not an address is a decoding error")
    func badControllerURL() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Settings.self, from: Data(#"{"controllerURL": "ftp://nope"}"#.utf8))
        }
    }

    @Test("the encoded file leaves controllerURL out when it is unset and lists the other keys")
    func encodedShape() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings())) as? [String: Any])
        #expect(Set(object.keys) == ["displayNameContains", "pollingIntervalSeconds", "localAPIPort", "launchAtLogin", "displaysToTurnOff"])
    }

    // MARK: Environment override

    @Test("SWITCHBOARD_CONTROLLER_URL overrides the saved controller URL")
    func environmentWins() {
        let settings = Settings(controllerURL: URL(string: "http://saved:1"))
        let url = settings.effectiveControllerURL(environment: ["SWITCHBOARD_CONTROLLER_URL": "http://env:2"])
        #expect(url?.absoluteString == "http://env:2")
        #expect(settings.controllerURLComesFromEnvironment(["SWITCHBOARD_CONTROLLER_URL": "http://env:2"]))
    }

    @Test("the saved URL applies when the environment does not say, or says something unusable")
    func environmentFallsBack() {
        let settings = Settings(controllerURL: URL(string: "http://saved:1"))
        for environment in [[:], ["SWITCHBOARD_CONTROLLER_URL": ""], ["SWITCHBOARD_CONTROLLER_URL": "ftp://x"], ["OTHER": "http://x"]] as [[String: String]] {
            #expect(settings.effectiveControllerURL(environment: environment)?.absoluteString == "http://saved:1")
            #expect(!settings.controllerURLComesFromEnvironment(environment))
        }
        #expect(Settings().effectiveControllerURL(environment: [:]) == nil)
    }

    @Test("the environment can name a controller when none is saved, with or without a scheme")
    func environmentAlone() {
        #expect(Settings().effectiveControllerURL(environment: ["SWITCHBOARD_CONTROLLER_URL": "http://127.0.0.1:48700"])?.absoluteString == "http://127.0.0.1:48700")
        #expect(Settings().effectiveControllerURL(environment: ["SWITCHBOARD_CONTROLLER_URL": "192.168.1.50:80"])?.absoluteString == "http://192.168.1.50:80")
    }

    @Test("controller addresses: http and https with a host; anything else is nil", arguments: [
        ("http://host:1", true), ("https://host", true), ("host:80", true), ("  http://host:1  ", true),
        ("", false), ("   ", false), ("ftp://host", false), ("http://", false), ("file:///tmp/x", false),
    ])
    func parse(text: String, valid: Bool) {
        #expect((Settings.parseControllerURL(text) != nil) == valid)
    }

    // MARK: set(_:to:)

    @Test("set changes one setting from its text form")
    func setValues() throws {
        var settings = Settings()
        try settings.set("controllerURL", to: "http://127.0.0.1:48700")
        try settings.set("displayNameContains", to: " DualUp ")
        try settings.set("pollingIntervalSeconds", to: "10")
        try settings.set("localAPIPort", to: "49000")
        try settings.set("launchAtLogin", to: "yes")
        #expect(settings == Settings(
            controllerURL: URL(string: "http://127.0.0.1:48700"), displayNameContains: "DualUp",
            pollingIntervalSeconds: 10, localAPIPort: 49000, launchAtLogin: true
        ))
        try settings.set("controllerURL", to: "none")
        #expect(settings.controllerURL == nil)
        try settings.set("launchAtLogin", to: "off")
        #expect(settings.launchAtLogin == false)
    }

    @Test("set refuses an unknown key or a value that does not fit, and leaves the settings alone", arguments: [
        ("controllr", "x"), ("controllerURL", "ftp://x"), ("displayNameContains", "  "), ("pollingIntervalSeconds", "0"),
        ("pollingIntervalSeconds", "abc"), ("pollingIntervalSeconds", "99999"), ("localAPIPort", "0"),
        ("localAPIPort", "70000"), ("localAPIPort", "x"), ("launchAtLogin", "maybe"),
    ])
    func setRefuses(key: String, value: String) {
        var settings = Settings()
        #expect(throws: SettingsError.self) { try settings.set(key, to: value) }
        #expect(settings == Settings())
    }

    @Test("text(for:) is what set accepts back")
    func textRoundTrip() throws {
        var settings = Settings(controllerURL: URL(string: "http://h:1"), pollingIntervalSeconds: 7.5, launchAtLogin: true)
        for key in Settings.Key.allCases {
            var copy = Settings()
            try copy.set(key.rawValue, to: settings.text(for: key))
            #expect(copy.text(for: key) == settings.text(for: key))
        }
        #expect(Settings().text(for: .controllerURL) == "none")
        #expect(Settings().text(for: .pollingIntervalSeconds) == "30")
        settings.pollingIntervalSeconds = 2
        #expect(settings.text(for: .pollingIntervalSeconds) == "2")
    }
}

@Suite("SettingsStore")
struct SettingsStoreTests {
    @Test("a missing file loads the defaults and writes nothing")
    func missingFile() async throws {
        try await withTempDirectory { directory in
            let store = SettingsStore(directory: directory)
            let loaded = try await store.load()
            #expect(loaded == Settings())
            #expect(!store.fileExists)
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }

    @Test("the first save creates the directory and settings.json")
    func firstSave() async throws {
        try await withTempDirectory { directory in
            let store = SettingsStore(directory: directory.appending(path: "nested/Switchboard"))
            try await store.save(Settings(localAPIPort: 49100))
            #expect(store.fileExists)
            #expect(store.fileURL.lastPathComponent == "settings.json")
            let loaded = try await store.load()
            #expect(loaded.localAPIPort == 49100)
        }
    }

    @Test("saved settings come back from a new store on the same directory")
    func roundTrip() async throws {
        try await withTempDirectory { directory in
            let settings = Settings(controllerURL: URL(string: "http://10.0.0.5:80"), displayNameContains: "X", pollingIntervalSeconds: 5, localAPIPort: 48601, launchAtLogin: true)
            try await SettingsStore(directory: directory).save(settings)
            let loaded = try await SettingsStore(directory: directory).load()
            #expect(loaded == settings)
        }
    }

    @Test("update loads, changes and saves, and returns the result")
    func update() async throws {
        try await withTempDirectory { directory in
            let store = SettingsStore(directory: directory)
            let result = try await store.update { $0.launchAtLogin = true }
            #expect(result.launchAtLogin)
            let loaded = try await store.load()
            #expect(loaded.launchAtLogin)
        }
    }

    @Test("a file that does not parse is an error and is left as it was")
    func corruptFile() async throws {
        try await withTempDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = SettingsStore(directory: directory)
            try Data("{ not json".utf8).write(to: store.fileURL)

            await #expect(throws: SettingsError.self) { try await store.load() }
            await #expect(throws: SettingsError.self) { try await store.update { $0.launchAtLogin = true } }
            #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == "{ not json")
        }
    }

    @Test("a hand-written file with only some keys is fine")
    func partialFile() async throws {
        try await withTempDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = SettingsStore(directory: directory)
            try Data(#"{"controllerURL": "http://127.0.0.1:48700"}"#.utf8).write(to: store.fileURL)
            let loaded = try await store.load()
            #expect(loaded.controllerURL?.absoluteString == "http://127.0.0.1:48700")
            #expect(loaded.localAPIPort == 48600)
        }
    }
}

@Suite("AppSupport")
struct AppSupportTests {
    @Test("the production directory is Application Support/Switchboard")
    func defaultDirectory() {
        let directory = AppSupport.defaultDirectory()
        #expect(directory.lastPathComponent == "Switchboard")
        #expect(directory.deletingLastPathComponent().lastPathComponent == "Application Support")
    }

    @Test("SWITCHBOARD_SUPPORT_DIR overrides it, an empty value does not")
    func override() {
        #expect(AppSupport.directory(environment: ["SWITCHBOARD_SUPPORT_DIR": "/tmp/sb-test"]).path == "/tmp/sb-test")
        #expect(AppSupport.directory(environment: ["SWITCHBOARD_SUPPORT_DIR": ""]) == AppSupport.defaultDirectory())
        #expect(AppSupport.directory(environment: [:]) == AppSupport.defaultDirectory())
    }
}

@Suite("Settings.displaysToTurnOff")
struct DisplaysToTurnOffTests {
    @Test("defaults to every display and survives a file without the key")
    func defaults() throws {
        #expect(Settings().displaysToTurnOff == [])
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(#"{"localAPIPort": 48600}"#.utf8))
        #expect(decoded.displaysToTurnOff == [])
    }

    @Test("set takes a comma-separated list, all or empty for every display, and text(for:) gives it back")
    func setAndText() throws {
        var settings = Settings()
        try settings.set("displaysToTurnOff", to: " LG SDQHD, 302NTCZ1U003 ,, ")
        #expect(settings.displaysToTurnOff == ["LG SDQHD", "302NTCZ1U003"])
        #expect(settings.text(for: .displaysToTurnOff) == "LG SDQHD, 302NTCZ1U003")
        try settings.set("displaysToTurnOff", to: "ALL")
        #expect(settings.displaysToTurnOff == [])
        #expect(settings.text(for: .displaysToTurnOff) == "all")
        try settings.set("displaysToTurnOff", to: "")
        #expect(settings.displaysToTurnOff == [])
    }

    @Test("round-trips through JSON as an array")
    func json() throws {
        let settings = Settings(displaysToTurnOff: ["LG SDQHD"])
        let data = try JSONEncoder().encode(settings)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["displaysToTurnOff"] as? [String] == ["LG SDQHD"])
        #expect(try JSONDecoder().decode(Settings.self, from: data) == settings)
    }
}
