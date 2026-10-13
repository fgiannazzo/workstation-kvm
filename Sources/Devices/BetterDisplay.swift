import Foundation
import SwitchboardCore

/// Why the display manager could not do what was asked. The text is what a failed run shows.
public enum DisplayConnectorError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    /// The tool exited non-zero. `output` is what it printed (BetterDisplay prints `Failed.`).
    case failed(command: String, status: Int32, output: String)
    case timedOut(command: String)
    /// The tool answered something this code does not understand.
    case invalidOutput(command: String, output: String)

    public var description: String {
        switch self {
        case .failed(let command, let status, let output):
            let said = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "BetterDisplay \(command) failed (exit \(status)\(said.isEmpty ? "" : ": \(said)"))"
        case .timedOut(let command):
            return "BetterDisplay \(command) did not answer in time; is BetterDisplay running?"
        case .invalidOutput(let command, let output):
            return "BetterDisplay \(command) answered something unexpected: \(output.prefix(200))"
        }
    }

    public var errorDescription: String? { description }
}

/// `DisplayConnector` through BetterDisplay's command line integration
/// (`BetterDisplay.app/Contents/MacOS/BetterDisplay`, BetterDisplay 5.1.1). The binary hands each
/// command to the running BetterDisplay app, so the app must be running with its CLI integration on
/// (the default). Connecting and disconnecting displays is a BetterDisplay Pro feature and needs a
/// natively connected display on Apple silicon.
///
/// Commands used, all addressed by the macOS display UUID:
///
/// - `get -identifiers`: every display and virtual screen as JSON objects separated by commas.
/// - `get -UUID=<uuid> -connected`: prints `on` or `off`; `Failed.` and exit 1 for an unknown display.
/// - `set -UUID=<uuid> -connected=on|off`.
/// - `perform -connectAllDisplays`: connects every display, listed or not.
///
/// It never sends a DDC command: macOS stops driving a disconnected display, which then goes to
/// standby for lack of signal.
public struct BetterDisplay: DisplayConnector {
    public static let defaultExecutable = URL(filePath: "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay")

    public let executable: URL
    private let timeout: Duration
    private let run: CommandRunner

    public init(executable: URL = Self.defaultExecutable, timeout: Duration = .seconds(10), run: @escaping CommandRunner = ProcessRunner.run) {
        self.executable = executable
        self.timeout = timeout
        self.run = run
    }

    /// BetterDisplay at `executable`, or nil when it is not installed there.
    public static func installed(at executable: URL = defaultExecutable) -> BetterDisplay? {
        FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false)) ? BetterDisplay(executable: executable) : nil
    }

    public func displays() async throws -> [ManagedDisplay] {
        let arguments = ["get", "-identifiers"]
        let output = try await call(arguments)
        guard let displays = Self.parseIdentifiers(output) else {
            throw DisplayConnectorError.invalidOutput(command: arguments.joined(separator: " "), output: output)
        }
        return displays
    }

    public func isConnected(_ display: ManagedDisplay) async throws -> Bool? {
        let arguments = ["get", "-UUID=\(display.uuid)", "-connected"]
        let result = try await invoke(arguments)
        // `Failed.`: BetterDisplay does not know a display with this UUID (any more).
        guard result.status == 0 else { return nil }
        switch result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "on": return true
        case "off": return false
        default: throw DisplayConnectorError.invalidOutput(command: arguments.joined(separator: " "), output: result.stdout)
        }
    }

    public func setConnected(_ display: ManagedDisplay, _ connected: Bool) async throws {
        _ = try await call(["set", "-UUID=\(display.uuid)", "-connected=\(connected ? "on" : "off")"])
    }

    public func connectAll() async throws {
        _ = try await call(["perform", "-connectAllDisplays"])
    }

    // MARK: Parsing

    /// The physical displays in `get -identifiers` output. BetterDisplay prints one JSON object per
    /// device separated by commas, with no enclosing brackets; a bracketed array is accepted too.
    /// Nil when the text is not that shape.
    ///
    /// Physical means `deviceType` `Display` with a hardware framebuffer behind it: a
    /// `registryLocation` naming `IOMobileFramebuffer` (Apple silicon, where connection management
    /// works at all). That leaves out display groups, BetterDisplay's own virtual screens, and the
    /// virtual displays remote-desktop tools create (Jump Desktop's), which may be listed as plain
    /// displays: switching those off would end the remote session.
    public static func parseIdentifiers(_ text: String) -> [ManagedDisplay]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        let array = trimmed.hasPrefix("[") ? trimmed : "[" + trimmed + "]"
        guard let objects = (try? JSONSerialization.jsonObject(with: Data(array.utf8))) as? [[String: Any]] else { return nil }
        return objects.compactMap { object in
            guard (object["deviceType"] as? String) == "Display",
                  let uuid = object["UUID"] as? String, !uuid.isEmpty,
                  let registry = object["registryLocation"] as? String, registry.contains("IOMobileFramebuffer")
            else { return nil }
            let name = (object["name"] as? String) ?? (object["productName"] as? String) ?? uuid
            let serial = (object["alphanumericSerial"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ManagedDisplay(name: name, uuid: uuid, serial: serial)
        }
    }

    // MARK: Running

    /// Runs and requires exit 0; returns stdout.
    private func call(_ arguments: [String]) async throws -> String {
        let result = try await invoke(arguments)
        guard result.status == 0 else {
            throw DisplayConnectorError.failed(command: arguments.joined(separator: " "), status: result.status, output: result.stdout + result.stderr)
        }
        return result.stdout
    }

    private func invoke(_ arguments: [String]) async throws -> CommandOutput {
        let result = try await run(executable, arguments, timeout)
        if result.timedOut { throw DisplayConnectorError.timedOut(command: arguments.joined(separator: " ")) }
        return result
    }
}
