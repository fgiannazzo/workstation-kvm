import Foundation
import StateStore
import SwitchboardCore

/// Why a set of macros is not acceptable. `description` names the macro and the step, so a
/// hand-edited `macros.json` points at its own mistake.
public enum MacroValidationError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    /// The id is empty or has characters that do not survive `POST /run/{id}`.
    case invalidID(String)
    case duplicateID(String)
    case noSteps(macro: String)
    /// A step's parameters are missing, mistyped or out of range. `step` counts from 1.
    case invalidStep(macro: String, step: Int, action: ActionID, error: ActionError)
    case invalidVerify(macro: String, reason: String)

    public var description: String {
        switch self {
        case .invalidID(let id):
            return "macro id \"\(id)\" must be letters, digits, \".\", \"_\" or \"-\", starting with a letter or digit"
        case .duplicateID(let id):
            return "macro id \"\(id)\" is used more than once"
        case .noSteps(let macro):
            return "macro \"\(macro)\" has no steps"
        case .invalidStep(let macro, let step, let action, let error):
            return "macro \"\(macro)\", step \(step) (\(action.rawValue)): \(error)"
        case .invalidVerify(let macro, let reason):
            return "macro \"\(macro)\", verify: \(reason)"
        }
    }

    public var errorDescription: String? { description }
}

/// Why `macros.json` could not be loaded or saved.
public enum MacroStoreError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case unreadable(path: String, detail: String)
    case invalidFile(path: String, detail: String)
    case invalid(MacroValidationError)
    case writeFailed(path: String, detail: String)

    public var description: String {
        switch self {
        case .unreadable(let path, let detail): return "cannot read \(path): \(detail)"
        case .invalidFile(let path, let detail): return "\(path) is not a valid macro file: \(detail)"
        case .invalid(let error): return error.description
        case .writeFailed(let path, let detail): return "cannot write \(path): \(detail)"
        }
    }

    public var errorDescription: String? { description }
}

/// The rules a macro file must satisfy. Pure; `MacroStore` applies them on load and save.
public enum MacroValidator {
    /// Ids appear in `POST /run/{id}` and `switchboard://run/{id}`.
    public static func isValidID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, first.isASCII, CharacterSet.alphanumerics.contains(first) else { return false }
        return id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0)) }
    }

    /// Unique valid ids; at least one step each; every step's parameters present, typed and in
    /// range for its action (the action itself is known by construction: `ActionID` is a closed
    /// enum, and an unknown one fails when the file is decoded); a verify that can only be met by a
    /// real reading (`unknown` is not a value to wait for).
    public static func validate(_ macros: [Macro], registry: ActionRegistry = ActionRegistry()) throws {
        var seen: Set<String> = []
        for macro in macros {
            guard isValidID(macro.id) else { throw MacroValidationError.invalidID(macro.id) }
            guard seen.insert(macro.id).inserted else { throw MacroValidationError.duplicateID(macro.id) }
            guard !macro.steps.isEmpty else { throw MacroValidationError.noSteps(macro: macro.id) }

            for (index, step) in macro.steps.enumerated() {
                do {
                    _ = try registry.validate(step.action, parameters: step.parameters)
                } catch let error as ActionError {
                    throw MacroValidationError.invalidStep(macro: macro.id, step: index + 1, action: step.action, error: error)
                }
            }

            if let verify = macro.verify {
                if verify.pbp == .unknown {
                    throw MacroValidationError.invalidVerify(macro: macro.id, reason: "pbp must be on or off")
                }
                if verify.mainInput == .unknown {
                    throw MacroValidationError.invalidVerify(macro: macro.id, reason: "mainInput must be hdmi1 or hdmi2")
                }
                if let port = verify.usbPort, !(1...4).contains(port) {
                    throw MacroValidationError.invalidVerify(macro: macro.id, reason: "usbPort must be 1 to 4, got \(port)")
                }
                for (display, input) in (verify.hdmiInput ?? [:]).sorted(by: { $0.key.rawValue < $1.key.rawValue }) where !(1...2).contains(input) {
                    throw MacroValidationError.invalidVerify(macro: macro.id, reason: "hdmiInput.\(display.rawValue) must be 1 or 2, got \(input)")
                }
            }
        }
    }
}

/// The macros, kept as `macros.json` in one directory (`~/Library/Application Support/Switchboard/`
/// in production, a temp directory in tests).
///
/// The first `load()` of a directory without a `macros.json` writes the two default macros,
/// `guest` and `solo`. A file that exists but is invalid is an error and is never overwritten.
/// Every write validates first, so the file on disk always satisfies `MacroValidator`.
public actor MacroStore {
    public static let fileName = "macros.json"

    public nonisolated let directory: URL
    private let registry: ActionRegistry
    private var cache: [Macro]?

    public init(directory: URL = AppSupport.defaultDirectory(), registry: ActionRegistry = ActionRegistry()) {
        self.directory = directory
        self.registry = registry
    }

    public nonisolated var fileURL: URL {
        directory.appending(path: Self.fileName, directoryHint: .notDirectory)
    }

    /// Shipped on first launch (`docs/DESIGN.md`, "Actions").
    ///
    /// - `guest`: PBP on, USB to port 2; afterwards PBP is on and the USB switch is on port 2.
    /// - `solo`: USB to port 1, PBP off; afterwards PBP is off and the USB switch is on port 1.
    public static let defaultMacros: [Macro] = [
        Macro(
            id: "guest", name: "Guest",
            steps: [
                MacroStep(action: .monitorPBPOn),
                MacroStep(action: .usbSelect, parameters: ["port": 2]),
            ],
            verify: MacroVerify(pbp: .on, usbPort: 2)
        ),
        Macro(
            id: "solo", name: "Solo",
            steps: [
                MacroStep(action: .usbSelect, parameters: ["port": 1]),
                MacroStep(action: .monitorPBPOff),
            ],
            verify: MacroVerify(pbp: .off, usbPort: 1)
        ),
    ]

    // MARK: Reading

    /// Reads `macros.json` (writing the defaults first when there is none) and returns the macros.
    /// Always goes to disk, so it picks up an edit made outside the process.
    @discardableResult
    public func load() throws -> [Macro] {
        let path = fileURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else {
            try write(Self.defaultMacros)
            cache = Self.defaultMacros
            return Self.defaultMacros
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw MacroStoreError.unreadable(path: path, detail: error.localizedDescription)
        }
        let file: MacroFile
        do {
            file = try JSONDecoder().decode(MacroFile.self, from: data)
        } catch {
            throw MacroStoreError.invalidFile(path: path, detail: Self.detail(error))
        }
        do {
            try MacroValidator.validate(file.macros, registry: registry)
        } catch let error as MacroValidationError {
            throw MacroStoreError.invalid(error)
        }
        cache = file.macros
        return file.macros
    }

    /// The macros, loading them on first use.
    public func macros() throws -> [Macro] {
        if let cache { return cache }
        return try load()
    }

    /// One macro by id; nil when there is none. Throws when the file cannot be loaded.
    public func macro(id: String) throws -> Macro? {
        try macros().first { $0.id == id }
    }

    // MARK: Writing

    /// Replaces all macros. Validates first; on error nothing is written.
    public func save(_ macros: [Macro]) throws {
        do {
            try MacroValidator.validate(macros, registry: registry)
        } catch let error as MacroValidationError {
            throw MacroStoreError.invalid(error)
        }
        try write(macros)
        cache = macros
    }

    /// Replaces the macro with the same id, or appends it.
    public func upsert(_ macro: Macro) throws {
        var all = try macros()
        if let index = all.firstIndex(where: { $0.id == macro.id }) {
            all[index] = macro
        } else {
            all.append(macro)
        }
        try save(all)
    }

    /// Removes a macro; false when there was none.
    @discardableResult
    public func remove(id: String) throws -> Bool {
        var all = try macros()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return false }
        all.remove(at: index)
        try save(all)
        return true
    }

    private func write(_ macros: [Macro]) throws {
        let path = fileURL.path(percentEncoded: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(MacroFile(macros: macros)).write(to: fileURL, options: .atomic)
        } catch {
            throw MacroStoreError.writeFailed(path: path, detail: error.localizedDescription)
        }
    }

    private static func detail(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        let context: DecodingError.Context
        switch decoding {
        case .dataCorrupted(let c), .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c): context = c
        @unknown default: return error.localizedDescription
        }
        let path = context.codingPath.map { $0.intValue.map { "[\($0 + 1)]" } ?? $0.stringValue }.joined(separator: " / ")
        return path.isEmpty ? context.debugDescription : "\(context.debugDescription) (at \(path))"
    }
}
