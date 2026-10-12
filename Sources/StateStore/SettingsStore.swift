import Foundation

/// Where the app keeps its files: `~/Library/Application Support/Switchboard/` (`settings.json`,
/// `macros.json`, `log.txt`; `docs/DESIGN.md`, "Names").
public enum AppSupport {
    /// Overrides the directory, for trying the CLI without touching the real settings and macros.
    public static let environmentKey = "SWITCHBOARD_SUPPORT_DIR"

    /// The production directory. Not created here; the stores create it on first write.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return base.appending(path: "Switchboard", directoryHint: .isDirectory)
    }

    /// `SWITCHBOARD_SUPPORT_DIR` when set and non-empty, else `defaultDirectory()`.
    public static func directory(environment: [String: String]) -> URL {
        if let raw = environment[environmentKey], !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        return defaultDirectory()
    }
}

/// Reads and writes `settings.json` in one directory (a temp directory in tests).
///
/// A missing file is not an error: `load()` returns the defaults and writes nothing; the file
/// appears on the first `save`. A file that exists but does not parse is an error, and is left
/// alone, so a typo never silently resets the settings.
public actor SettingsStore {
    public static let fileName = "settings.json"

    public nonisolated let directory: URL

    public init(directory: URL = AppSupport.defaultDirectory()) {
        self.directory = directory
    }

    public nonisolated var fileURL: URL {
        directory.appending(path: Self.fileName, directoryHint: .notDirectory)
    }

    /// Whether `settings.json` exists yet.
    public nonisolated var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false))
    }

    public func load() throws -> Settings {
        guard fileExists else { return Settings() }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw SettingsError("cannot read \(fileURL.path(percentEncoded: false)): \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            throw SettingsError("\(fileURL.path(percentEncoded: false)) is not a valid settings file: \(Self.detail(error))")
        }
    }

    /// Writes the whole file (creating the directory), atomically.
    public func save(_ settings: Settings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(settings).write(to: fileURL, options: .atomic)
        } catch {
            throw SettingsError("cannot write \(fileURL.path(percentEncoded: false)): \(error.localizedDescription)")
        }
    }

    /// Load, change, save; returns what was saved.
    @discardableResult
    public func update(_ change: @Sendable (inout Settings) throws -> Void) throws -> Settings {
        var settings = try load()
        try change(&settings)
        try save(settings)
        return settings
    }

    private static func detail(_ error: any Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .dataCorrupted(let context), .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context):
                return context.debugDescription
            @unknown default:
                break
            }
        }
        return error.localizedDescription
    }
}
