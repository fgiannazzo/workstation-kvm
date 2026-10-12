import Actions
import Foundation
import SwitchboardCore
import Testing

private func macro(_ id: String = "m", steps: [MacroStep]? = nil, verify: MacroVerify? = nil) -> Macro {
    Macro(id: id, name: id.capitalized, steps: steps ?? [MacroStep(action: .monitorRead)], verify: verify)
}

@Suite("MacroStore")
struct MacroStoreTests {
    @Test("the first load in an empty directory writes the default macros and returns them")
    func firstLoadCreatesDefaults() async throws {
        try await withTempDirectory { directory in
            let store = MacroStore(directory: directory)
            #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))

            let macros = try await store.load()
            #expect(macros.map(\.id) == ["guest", "solo"])
            #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
            #expect(store.fileURL.lastPathComponent == "macros.json")

            let guest = try #require(macros.first { $0.id == "guest" })
            #expect(guest.steps == [MacroStep(action: .monitorPBPOn), MacroStep(action: .usbSelect, parameters: ["port": 2])])
            #expect(guest.verify == MacroVerify(pbp: .on, usbPort: 2))

            let solo = try #require(macros.first { $0.id == "solo" })
            #expect(solo.steps == [MacroStep(action: .usbSelect, parameters: ["port": 1]), MacroStep(action: .monitorPBPOff)])
            #expect(solo.verify == MacroVerify(pbp: .off, usbPort: 1))
        }
    }

    @Test("a new store on the same directory reads the macros back")
    func readBack() async throws {
        try await withTempDirectory { directory in
            _ = try await MacroStore(directory: directory).load()
            let again = try await MacroStore(directory: directory).load()
            #expect(again == MacroStore.defaultMacros)

            let file = try JSONDecoder().decode(MacroFile.self, from: Data(contentsOf: MacroStore(directory: directory).fileURL))
            #expect(file.macros == MacroStore.defaultMacros)
        }
    }

    @Test("the file on disk is the API.md shape")
    func fileShape() async throws {
        try await withTempDirectory { directory in
            let store = MacroStore(directory: directory)
            _ = try await store.load()
            let onDisk = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: store.fileURL))
            #expect(onDisk == (try jsonTree(apiMacrosJSON)))
        }
    }

    @Test("defaults are written once: an edited file is not overwritten by a later load")
    func defaultsOnlyOnce() async throws {
        try await withTempDirectory { directory in
            let store = MacroStore(directory: directory)
            try await store.save([macro("only")])
            let got1 = try await MacroStore(directory: directory).load().map(\.id)
            #expect(got1 == ["only"])
        }
    }

    @Test("macro(id:) finds a macro and is nil for an unknown id")
    func lookUp() async throws {
        try await withTempDirectory { directory in
            let store = MacroStore(directory: directory)
            let got2 = try await store.macro(id: "guest")?.name
            #expect(got2 == "Guest")
            let got3 = try await store.macro(id: "nope")
            #expect(got3 == nil)
        }
    }

    @Test("save replaces everything, upsert replaces or appends, remove deletes")
    func editing() async throws {
        try await withTempDirectory { directory in
            let store = MacroStore(directory: directory)
            try await store.save([macro("a"), macro("b")])
            let got4 = try await store.macros().map(\.id)
            #expect(got4 == ["a", "b"])

            try await store.upsert(Macro(id: "a", name: "Renamed", steps: [MacroStep(action: .delay, parameters: ["ms": 10])]))
            try await store.upsert(macro("c"))
            let got5 = try await store.macros().map(\.id)
            #expect(got5 == ["a", "b", "c"])
            let got6 = try await store.macro(id: "a")?.name
            #expect(got6 == "Renamed")

            let removed = try await store.remove(id: "b")
            #expect(removed)
            let removedAgain = try await store.remove(id: "b")
            #expect(!removedAgain)
            let got7 = try await MacroStore(directory: directory).load().map(\.id)
            #expect(got7 == ["a", "c"])
        }
    }

    @Test("upsert on an empty directory starts from the defaults")
    func upsertStartsFromDefaults() async throws {
        try await withTempDirectory { directory in
            let store = MacroStore(directory: directory)
            try await store.upsert(macro("extra"))
            let got8 = try await store.macros().map(\.id)
            #expect(got8 == ["guest", "solo", "extra"])
        }
    }

    // MARK: Invalid input

    @Test("an invalid macro is refused and nothing is written")
    func saveValidates() async throws {
        try await withTempDirectory { directory in
            let store = MacroStore(directory: directory)
            try await store.save([macro("ok")])
            let before = try Data(contentsOf: store.fileURL)

            await #expect(throws: MacroStoreError.self) { try await store.save([macro("a"), macro("a")]) }
            await #expect(throws: MacroStoreError.self) { try await store.upsert(macro("bad id")) }
            #expect(try Data(contentsOf: store.fileURL) == before)
            let got9 = try await store.macros().map(\.id)
            #expect(got9 == ["ok"])
        }
    }

    @Test("a file that is not JSON is an error and is left untouched")
    func corruptFile() async throws {
        try await withTempDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = MacroStore(directory: directory)
            try Data("{ nope".utf8).write(to: store.fileURL)

            await #expect(throws: MacroStoreError.self) { try await store.load() }
            #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == "{ nope")
        }
    }

    @Test("an unknown action in the file is reported with the macro and step it is in")
    func unknownActionInFile() async throws {
        try await withTempDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = MacroStore(directory: directory)
            let json = #"{"macros": [{"id": "x", "name": "X", "steps": [{"action": "monitor.read"}, {"action": "tv.on"}]}]}"#
            try Data(json.utf8).write(to: store.fileURL)

            do {
                _ = try await store.load()
                Issue.record("expected an error")
            } catch let error as MacroStoreError {
                guard case .invalidFile(_, let detail) = error else { Issue.record("wrong error \(error)"); return }
                #expect(detail.contains("tv.on"))
                #expect(detail.contains("[2]"))   // the second step
            }
        }
    }

    @Test("a file with an out-of-range parameter fails validation on load")
    func invalidParameterInFile() async throws {
        try await withTempDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = MacroStore(directory: directory)
            let json = #"{"macros": [{"id": "x", "name": "X", "steps": [{"action": "usb.select", "port": 9}]}]}"#
            try Data(json.utf8).write(to: store.fileURL)

            do {
                _ = try await store.load()
                Issue.record("expected an error")
            } catch let error as MacroStoreError {
                guard case .invalid(.invalidStep(let id, let step, let action, _)) = error else { Issue.record("wrong error \(error)"); return }
                #expect((id, step, action) == ("x", 1, .usbSelect))
            }
        }
    }
}

@Suite("MacroValidator")
struct MacroValidatorTests {
    private func validate(_ macros: [Macro]) -> MacroValidationError? {
        do {
            try MacroValidator.validate(macros)
            return nil
        } catch let error as MacroValidationError {
            return error
        } catch {
            Issue.record("wrong error \(error)")
            return nil
        }
    }

    @Test("the default macros are valid")
    func defaultsAreValid() {
        #expect(validate(MacroStore.defaultMacros) == nil)
    }

    @Test("a macro of every action with good parameters is valid")
    func everyActionValid() {
        let steps = [
            MacroStep(action: .monitorPBPOn), MacroStep(action: .monitorPBPOff), MacroStep(action: .monitorRead),
            MacroStep(action: .hdmiSelect, parameters: ["display": "samsung", "input": 1]),
            MacroStep(action: .hdmiResync, parameters: ["display": "dualup", "input": 2]),
            MacroStep(action: .usbSelect, parameters: ["port": 4]),
            MacroStep(action: .delay, parameters: ["ms": 0]), MacroStep(action: .delay, parameters: ["ms": 60000]),
            MacroStep(action: .notify, parameters: ["text": ""]),
        ]
        #expect(validate([macro(steps: steps, verify: MacroVerify(pbp: .off, mainInput: .hdmi2, usbPort: 4, hdmiInput: [.lg4k: 2]))]) == nil)
    }

    @Test("ids must be unique", arguments: [["a", "a"], ["a", "b", "a"]])
    func duplicateIDs(ids: [String]) {
        #expect(validate(ids.map { macro($0) }) == .duplicateID("a"))
    }

    @Test("ids must be usable in a URL path", arguments: ["", " ", "has space", "a/b", "-lead", ".lead", "ünï", "a?b", "a#b"])
    func invalidIDs(id: String) {
        #expect(validate([macro(id)]) == .invalidID(id))
    }

    @Test("ordinary ids are fine", arguments: ["guest", "Guest2", "lg4k-on", "a.b_c", "0"])
    func validIDs(id: String) {
        #expect(validate([macro(id)]) == nil)
    }

    @Test("a macro needs at least one step")
    func noSteps() {
        #expect(validate([macro("m", steps: [])]) == .noSteps(macro: "m"))
    }

    @Test("required parameters must be present, and the first problem names its step")
    func missingParameter() {
        let error = validate([macro("m", steps: [MacroStep(action: .monitorRead), MacroStep(action: .usbSelect)])])
        #expect(error == .invalidStep(macro: "m", step: 2, action: .usbSelect, error: .missingParameter("port")))
        #expect(error?.description == "macro \"m\", step 2 (usb.select): missing parameter \"port\"")
    }

    @Test("parameters must be in range", arguments: [
        (ActionID.usbSelect, ["port": JSONValue.int(0)]), (.usbSelect, ["port": .int(5)]),
        (.hdmiSelect, ["display": .string("lg4k"), "input": .int(3)]), (.hdmiSelect, ["display": .string("tv"), "input": .int(1)]),
        (.delay, ["ms": .int(-1)]), (.delay, ["ms": .int(60001)]),
        (.usbSelect, ["port": .string("2")]), (.usbSelect, ["port": .double(2.5)]), (.notify, ["text": .int(5)]),
        (.usbSelect, ["port": .int(2), "extra": .int(1)]),
    ])
    func outOfRange(action: ActionID, parameters: [String: JSONValue]) {
        let error = validate([macro(steps: [MacroStep(action: action, parameters: parameters)])])
        guard case .invalidStep(_, 1, let found, _)? = error else { Issue.record("expected an invalid step, got \(String(describing: error))"); return }
        #expect(found == action)
    }

    @Test("verify must be satisfiable by a real reading")
    func verifyRules() {
        #expect(validate([macro(verify: MacroVerify(pbp: .unknown))]) == .invalidVerify(macro: "m", reason: "pbp must be on or off"))
        #expect(validate([macro(verify: MacroVerify(mainInput: .unknown))]) == .invalidVerify(macro: "m", reason: "mainInput must be hdmi1 or hdmi2"))
        #expect(validate([macro(verify: MacroVerify(usbPort: 5))]) == .invalidVerify(macro: "m", reason: "usbPort must be 1 to 4, got 5"))
        #expect(validate([macro(verify: MacroVerify(hdmiInput: [.samsung: 3]))]) == .invalidVerify(macro: "m", reason: "hdmiInput.samsung must be 1 or 2, got 3"))
    }
}
