import Actions
import AppCore
import Foundation
import StateStore
import SwitchboardCore
import Testing

@Suite("MacroDraft")
struct MacroDraftTests {
    private let registry = ActionRegistry()

    /// A draft that is valid as it stands.
    private func guest() -> MacroDraft {
        MacroDraft(macro: MacroStore.defaultMacros[0])
    }

    private func messages(_ draft: MacroDraft, among others: [MacroDraft] = []) -> [String] {
        draft.issues(among: [draft] + others).map(\.description)
    }

    // MARK: Round trip

    @Test("a macro becomes a draft and back unchanged, for the shipped defaults too")
    func roundTrip() {
        for macro in MacroStore.defaultMacros {
            #expect(MacroDraft(macro: macro).macro() == macro)
        }
        let withEverything = Macro(
            id: "all", name: "All",
            steps: [
                MacroStep(action: .hdmiSelect, parameters: ["display": "lg4k", "input": 2]),
                MacroStep(action: .delay, parameters: ["ms": 500]),
                MacroStep(action: .notify, parameters: ["text": "Guest mode"]),
            ],
            verify: MacroVerify(pbp: .on, mainInput: .hdmi1, usbPort: 2, hdmiInput: [.lg4k: 2])
        )
        #expect(MacroDraft(macro: withEverything).macro() == withEverything)
    }

    @Test("a verify with nothing set is saved as no verify at all")
    func emptyVerify() {
        var draft = guest()
        draft.verify = VerifyDraft()
        #expect(draft.macro().verify == nil)
    }

    // MARK: Valid drafts

    @Test("the defaults have no issues, and the store accepts what the drafts convert to")
    func defaultsAreValid() throws {
        let drafts = MacroStore.defaultMacros.map(MacroDraft.init(macro:))
        #expect(MacroDraftSet.issues(in: drafts).isEmpty)
        try MacroValidator.validate(MacroDraftSet.macros(from: drafts))
    }

    @Test("a new macro starts empty and asks for a step; with one it is valid")
    func newMacro() {
        var draft = MacroDraft.new(among: [])
        #expect(draft.macroID == "new-macro")
        #expect(messages(draft) == ["add at least one step"])

        draft.addStep(.monitorRead)
        #expect(messages(draft) == [])
    }

    // MARK: Ids

    @Test("an empty id, an id with a space and an id that starts with a dash are refused")
    func badIDs() {
        var draft = guest()
        draft.macroID = ""
        #expect(messages(draft) == ["the id is empty"])

        draft.macroID = "my macro"
        #expect(messages(draft).first?.contains("must be letters, digits") == true)

        draft.macroID = "-x"
        #expect(messages(draft).first?.contains("must be letters, digits") == true)
    }

    @Test("the same rule as the store: letters, digits, dot, underscore, dash")
    func idRuleMatchesStore() {
        for id in ["guest", "a.b_c-d", "9lives", "usb.select"] {
            var draft = guest()
            draft.macroID = id
            #expect(draft.issues(among: [draft]).isEmpty, "\(id) is a valid id")
            #expect(MacroValidator.isValidID(id))
        }
        for id in ["", " ", "a b", "_x", "é", "a/b"] {
            var draft = guest()
            draft.macroID = id
            #expect(!draft.issues(among: [draft]).isEmpty, "\"\(id)\" is not a valid id")
            #expect(!MacroValidator.isValidID(id))
        }
    }

    @Test("ids must be unique across the list, ignoring surrounding spaces")
    func duplicateIDs() {
        let first = guest()
        var second = MacroDraft(macro: MacroStore.defaultMacros[1])
        second.macroID = " guest "

        #expect(messages(second, among: [first]) == ["macro id \"guest\" is used more than once"])
        #expect(first.issues(among: [first, second]).map(\.description) == ["macro id \"guest\" is used more than once"])
        #expect(!MacroDraftSet.isValid([first, second]))
    }

    @Test("a macro does not clash with itself")
    func ownID() {
        let draft = guest()
        #expect(draft.issues(among: [draft]).isEmpty)
    }

    @Test("an empty name is refused")
    func emptyName() {
        var draft = guest()
        draft.name = "  "
        #expect(messages(draft) == ["the name is empty"])
    }

    // MARK: Steps

    @Test("a macro with no steps is refused")
    func noSteps() {
        var draft = guest()
        draft.steps = []
        #expect(messages(draft) == ["add at least one step"])
    }

    @Test("a new step of each action starts with valid parameters, except text, which must be written")
    func newStepsStartValid() {
        for descriptor in registry.descriptors {
            var draft = MacroDraft(macroID: "x", name: "X")
            draft.addStep(descriptor.id)
            let needsText = descriptor.parameters.contains { $0.type == .string }
            #expect(draft.issues(among: [draft]).isEmpty == !needsText, "\(descriptor.id.rawValue)")
        }
    }

    @Test("every required parameter of the action must be filled in")
    func requiredParameters() {
        var draft = MacroDraft(macroID: "x", name: "X")
        draft.addStep(.hdmiSelect)
        draft.steps[0].values["display"] = ""
        draft.steps[0].values["input"] = ""
        #expect(messages(draft) == [
            "Step 1: hdmi.select: display is required",
            "Step 1: hdmi.select: input is required",
        ])
    }

    @Test("notify needs text")
    func notifyNeedsText() {
        var draft = MacroDraft(macroID: "x", name: "X")
        draft.addStep(.notify)
        #expect(messages(draft) == ["Step 1: notify: text is required"])
        draft.steps[0].values["text"] = "Hello"
        #expect(messages(draft) == [])
    }

    @Test("integers must be whole numbers inside the action's range")
    func integerRange() {
        var draft = MacroDraft(macroID: "x", name: "X")
        draft.addStep(.usbSelect)

        draft.steps[0].values["port"] = "5"
        #expect(messages(draft) == ["Step 1: usb.select: invalid parameter \"port\": must be 1 to 4, got 5"])

        draft.steps[0].values["port"] = "two"
        #expect(messages(draft).first?.contains("must be a whole number") == true)

        draft.steps[0].values["port"] = "4"
        #expect(messages(draft) == [])

        var delay = MacroDraft(macroID: "y", name: "Y")
        delay.addStep(.delay)
        delay.steps[0].values["ms"] = "60001"
        #expect(delay.issues(among: [delay]).count == 1)
        delay.steps[0].values["ms"] = "60000"
        #expect(delay.issues(among: [delay]).isEmpty)
    }

    @Test("a choice must be one of the action's values")
    func choice() {
        var draft = MacroDraft(macroID: "x", name: "X")
        draft.addStep(.hdmiResync)
        draft.steps[0].values["display"] = "tv"
        #expect(messages(draft).first?.contains("must be one of dualup, lg4k, samsung") == true)
    }

    @Test("issues name the step they belong to")
    func stepNumbers() {
        var draft = guest()
        draft.addStep(.usbSelect)
        draft.steps[2].values["port"] = "9"
        #expect(draft.issues(among: [draft]).map(\.step) == [3])
    }

    @Test("changing a step's action resets its parameters and keeps the step's identity")
    func changeAction() {
        var step = StepDraft(action: .usbSelect)
        let identity = step.id
        step.values["port"] = "3"

        step.setAction(.hdmiSelect)
        #expect(step.id == identity)
        #expect(step.action == .hdmiSelect)
        #expect(step.values == ["display": "dualup", "input": "1"])

        step.setAction(.hdmiSelect)
        #expect(step.values == ["display": "dualup", "input": "1"], "choosing the same action changes nothing")
    }

    // MARK: Verify

    @Test("verify values the store would refuse are refused")
    func verifyRanges() {
        var draft = guest()
        draft.verify = VerifyDraft(usbPort: 7)
        #expect(messages(draft) == ["verify: usbPort must be 1 to 4, got 7"])

        draft.verify = VerifyDraft(hdmiInput: [.lg4k: 3])
        #expect(messages(draft) == ["verify: hdmiInput.lg4k must be 1 or 2, got 3"])

        draft.verify = VerifyDraft(pbp: .unknown)
        #expect(messages(draft) == ["verify: pbp must be on or off"])

        draft.verify = VerifyDraft(pbp: .on, mainInput: .hdmi2, usbPort: 2, hdmiInput: [.dualup: 1])
        #expect(messages(draft) == [])
    }

    // MARK: Editing

    @Test("steps move up and down, and stop at the ends")
    func moveSteps() {
        var draft = MacroDraft(macroID: "x", name: "X")
        draft.addStep(.monitorPBPOn)
        draft.addStep(.monitorRead)
        draft.addStep(.monitorPBPOff)
        let ids = draft.steps.map(\.id)
        func order() -> [ActionID] { draft.steps.map(\.action) }

        draft.moveStep(id: ids[2], by: -1)
        #expect(order() == [.monitorPBPOn, .monitorPBPOff, .monitorRead])

        draft.moveStep(id: ids[1], by: 1)
        #expect(order() == [.monitorPBPOn, .monitorPBPOff, .monitorRead], "already last")

        draft.moveStep(id: ids[0], by: -1)
        #expect(order() == [.monitorPBPOn, .monitorPBPOff, .monitorRead], "already first")

        draft.moveStep(id: ids[0], by: 1)
        #expect(order() == [.monitorPBPOff, .monitorPBPOn, .monitorRead])
    }

    @Test("a step is removed by its identity")
    func removeStep() {
        var draft = guest()
        let first = draft.steps[0].id
        draft.removeStep(id: first)
        #expect(draft.steps.map(\.action) == [.usbSelect])
        draft.removeStep(id: first)
        #expect(draft.steps.count == 1)
    }

    @Test("duplicates take a free id, a new identity and their own steps")
    func duplicate() {
        let original = guest()
        let copy = original.duplicate(among: [original])
        #expect(copy.macroID == "guest-copy")
        #expect(copy.name == "Guest copy")
        #expect(copy.id != original.id)
        #expect(copy.steps.map(\.id).allSatisfy { id in !original.steps.map(\.id).contains(id) })
        #expect(copy.macro().steps == original.macro().steps)
        #expect(copy.macro().verify == original.macro().verify)

        let second = original.duplicate(among: [original, copy])
        #expect(second.macroID == "guest-copy-2")

        let both = [original, copy, second]
        #expect(MacroDraftSet.issues(in: both).isEmpty)
    }

    @Test("unique ids count up from 2")
    func uniqueID() {
        #expect(MacroDraft.uniqueID(base: "a", among: []) == "a")
        #expect(MacroDraft.uniqueID(base: "a", among: ["a"]) == "a-2")
        #expect(MacroDraft.uniqueID(base: "a", among: ["a", "a-2", "a-3"]) == "a-4")
    }

    @Test("two new macros in a row get different ids")
    func newMacrosDiffer() {
        let first = MacroDraft.new(among: [])
        let second = MacroDraft.new(among: [first])
        #expect(first.macroID == "new-macro")
        #expect(second.macroID == "new-macro-2")
    }

    @Test("whitespace around the id and name is trimmed in the macro")
    func trimming() {
        var draft = guest()
        draft.macroID = "  guest2 "
        draft.name = " Guest two "
        #expect(draft.macro().id == "guest2")
        #expect(draft.macro().name == "Guest two")
        #expect(draft.issues(among: [draft]).isEmpty)
    }

    @Test("a list of valid drafts is what MacroStore.save accepts")
    func storeAgrees() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "switchboard-draft-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        var extra = MacroDraft.new(among: [])
        extra.addStep(.delay)
        extra.steps[0].values["ms"] = "250"
        extra.addStep(.notify)
        extra.steps[1].values["text"] = "Done"
        extra.verify = VerifyDraft(pbp: .off)
        let drafts = MacroStore.defaultMacros.map(MacroDraft.init(macro:)) + [extra]
        #expect(MacroDraftSet.issues(in: drafts).isEmpty)

        let store = MacroStore(directory: directory)
        try await store.save(MacroDraftSet.macros(from: drafts))
        let reloaded = try await store.load()
        #expect(reloaded.map(\.id) == ["guest", "solo", "new-macro"])
        #expect(reloaded[2].steps == [
            MacroStep(action: .delay, parameters: ["ms": 250]),
            MacroStep(action: .notify, parameters: ["text": "Done"]),
        ])
    }
}
