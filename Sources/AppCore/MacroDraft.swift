import Actions
import Foundation
import SwitchboardCore

// The macro editor edits drafts, not `Macro` values: text fields hold text, a half-typed id is not
// a valid id, and a step can be mid-edit. A draft converts to a `Macro` at any time (`macro(...)`),
// and `issues(...)` says what is wrong with it, using the same rules as `MacroStore` so a draft
// without issues is accepted by `MacroStore.save`. The store still validates on write; this is
// for showing the problems next to the fields before the user presses Save.

/// One step being edited: an action and, per parameter of that action, the text in its control.
public struct StepDraft: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var action: ActionID
    /// Parameter name to the text shown in its control (`"2"` for `port`, `"lg4k"` for `display`).
    public var values: [String: String]

    /// A new step with each parameter at its starting value: the lowest number, the first choice,
    /// empty text.
    public init(action: ActionID, registry: ActionRegistry = ActionRegistry()) {
        self.id = UUID()
        self.action = action
        var values: [String: String] = [:]
        for parameter in registry.descriptor(for: action).parameters {
            switch parameter.type {
            case .int: values[parameter.name] = String(parameter.min ?? 0)
            case .choice: values[parameter.name] = parameter.values?.first ?? ""
            case .string: values[parameter.name] = ""
            }
        }
        self.values = values
    }

    public init(step: MacroStep) {
        self.id = UUID()
        self.action = step.action
        self.values = step.parameters.mapValues { value in
            if let text = value.stringValue { return text }
            if let number = value.intValue { return String(number) }
            return value.description
        }
    }

    /// The typed parameters: integers for `int` parameters whose text is a number, text otherwise
    /// (so validation can say what is wrong instead of this guessing).
    public func parameters(registry: ActionRegistry = ActionRegistry()) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for parameter in registry.descriptor(for: action).parameters {
            let text = (values[parameter.name] ?? "")
            result[parameter.name] = parameter.value(fromText: text)
        }
        return result
    }

    public var step: MacroStep {
        MacroStep(action: action, parameters: parameters())
    }

    /// Changes the action and resets the parameters to that action's starting values. The step keeps
    /// its identity, so a list keeps its selection and scroll position.
    public mutating func setAction(_ newAction: ActionID, registry: ActionRegistry = ActionRegistry()) {
        guard newAction != action else { return }
        action = newAction
        values = StepDraft(action: newAction, registry: registry).values
    }
}

/// The optional `verify` of a macro. `nil` means the field is not checked.
public struct VerifyDraft: Equatable, Sendable {
    /// `.on` or `.off` (`.unknown` is not a value to wait for).
    public var pbp: PBPState?
    /// `.hdmi1` or `.hdmi2`.
    public var mainInput: MainInput?
    public var usbPort: Int?
    public var hdmiInput: [DisplayID: Int]

    public init(pbp: PBPState? = nil, mainInput: MainInput? = nil, usbPort: Int? = nil, hdmiInput: [DisplayID: Int] = [:]) {
        self.pbp = pbp
        self.mainInput = mainInput
        self.usbPort = usbPort
        self.hdmiInput = hdmiInput
    }

    public init(_ verify: MacroVerify?) {
        self.init(pbp: verify?.pbp, mainInput: verify?.mainInput, usbPort: verify?.usbPort, hdmiInput: verify?.hdmiInput ?? [:])
    }

    public var isEmpty: Bool {
        pbp == nil && mainInput == nil && usbPort == nil && hdmiInput.isEmpty
    }

    /// nil when nothing is checked, so the macro is saved without a `verify` key.
    public var verify: MacroVerify? {
        isEmpty ? nil : MacroVerify(pbp: pbp, mainInput: mainInput, usbPort: usbPort, hdmiInput: hdmiInput.isEmpty ? nil : hdmiInput)
    }
}

/// One thing wrong with a draft.
public struct DraftIssue: Equatable, Sendable, CustomStringConvertible {
    /// The 1-based step it concerns; nil for the macro as a whole.
    public var step: Int?
    public var message: String

    public init(step: Int? = nil, message: String) {
        self.step = step
        self.message = message
    }

    public var description: String {
        step.map { "Step \($0): \(message)" } ?? message
    }
}

/// A macro being edited.
public struct MacroDraft: Identifiable, Equatable, Sendable {
    /// Identity inside the editor; stays put while `macroID` is being typed.
    public let id: UUID
    /// The macro's own id, as in `switchboard://run/{id}`.
    public var macroID: String
    public var name: String
    public var steps: [StepDraft]
    public var verify: VerifyDraft

    public init(macroID: String, name: String, steps: [StepDraft] = [], verify: VerifyDraft = VerifyDraft()) {
        self.id = UUID()
        self.macroID = macroID
        self.name = name
        self.steps = steps
        self.verify = verify
    }

    public init(macro: Macro) {
        self.init(
            macroID: macro.id,
            name: macro.name,
            steps: macro.steps.map(StepDraft.init(step:)),
            verify: VerifyDraft(macro.verify)
        )
    }

    /// An empty macro with an id that no draft in `existing` has.
    public static func new(among existing: [MacroDraft]) -> MacroDraft {
        MacroDraft(macroID: uniqueID(base: "new-macro", among: existing.map(\.macroID)), name: "New macro")
    }

    /// A copy under a free id (`guest-copy`, then `guest-copy-2`), with fresh step identities.
    public func duplicate(among existing: [MacroDraft]) -> MacroDraft {
        MacroDraft(
            macroID: Self.uniqueID(base: macroID + "-copy", among: existing.map(\.macroID)),
            name: name + " copy",
            steps: steps.map { StepDraft(step: $0.step) },
            verify: verify
        )
    }

    /// `base`, or `base-2`, `base-3`, ... when taken.
    public static func uniqueID(base: String, among taken: [String]) -> String {
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base)-\(number)") { number += 1 }
        return "\(base)-\(number)"
    }

    // MARK: Editing steps

    public mutating func addStep(_ action: ActionID, registry: ActionRegistry = ActionRegistry()) {
        steps.append(StepDraft(action: action, registry: registry))
    }

    public mutating func removeStep(id: UUID) {
        steps.removeAll { $0.id == id }
    }

    /// Moves a step up (`offset` -1) or down (+1); does nothing at the ends.
    public mutating func moveStep(id: UUID, by offset: Int) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard steps.indices.contains(target) else { return }
        steps.swapAt(index, target)
    }

    // MARK: Converting and checking

    /// The macro this draft stands for (id and name trimmed). Not validated; see `issues`.
    public func macro(registry: ActionRegistry = ActionRegistry()) -> Macro {
        Macro(
            id: macroID.trimmingCharacters(in: .whitespacesAndNewlines),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            steps: steps.map { MacroStep(action: $0.action, parameters: $0.parameters(registry: registry)) },
            verify: verify.verify
        )
    }

    /// Everything wrong with this draft, given the other drafts it will be saved with (for the
    /// uniqueness of the id). Empty when `MacroStore.save` would accept it.
    public func issues(among drafts: [MacroDraft], registry: ActionRegistry = ActionRegistry()) -> [DraftIssue] {
        var issues: [DraftIssue] = []
        let converted = macro(registry: registry)

        if converted.id.isEmpty {
            issues.append(DraftIssue(message: "the id is empty"))
        } else if !MacroValidator.isValidID(converted.id) {
            issues.append(DraftIssue(message: MacroValidationError.invalidID(converted.id).description))
        } else if drafts.contains(where: { $0.id != id && $0.macroID.trimmingCharacters(in: .whitespacesAndNewlines) == converted.id }) {
            issues.append(DraftIssue(message: MacroValidationError.duplicateID(converted.id).description))
        }
        if converted.name.isEmpty {
            issues.append(DraftIssue(message: "the name is empty"))
        }
        if steps.isEmpty {
            issues.append(DraftIssue(message: "add at least one step"))
        }

        for (index, draft) in steps.enumerated() {
            let number = index + 1
            let descriptor = registry.descriptor(for: draft.action)
            var stepIssues = 0
            // Required parameters: a control left empty is a parameter not given.
            for parameter in descriptor.parameters where (draft.values[parameter.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(DraftIssue(step: number, message: "\(draft.action.rawValue): \(parameter.name) is required"))
                stepIssues += 1
            }
            if stepIssues == 0 {
                do {
                    _ = try registry.validate(draft.action, parameters: draft.parameters(registry: registry))
                } catch {
                    issues.append(DraftIssue(step: number, message: "\(draft.action.rawValue): \(error)"))
                }
            }
        }

        if let verify = converted.verify {
            if verify.pbp == .unknown { issues.append(DraftIssue(message: "verify: pbp must be on or off")) }
            if verify.mainInput == .unknown { issues.append(DraftIssue(message: "verify: mainInput must be hdmi1 or hdmi2")) }
            if let port = verify.usbPort, !(1...4).contains(port) {
                issues.append(DraftIssue(message: "verify: usbPort must be 1 to 4, got \(port)"))
            }
            for (display, input) in (verify.hdmiInput ?? [:]).sorted(by: { $0.key.rawValue < $1.key.rawValue }) where !(1...2).contains(input) {
                issues.append(DraftIssue(message: "verify: hdmiInput.\(display.rawValue) must be 1 or 2, got \(input)"))
            }
        }
        return issues
    }
}

/// Checks over the whole list the editor is showing.
public enum MacroDraftSet {
    /// The macros the drafts stand for, in order.
    public static func macros(from drafts: [MacroDraft], registry: ActionRegistry = ActionRegistry()) -> [Macro] {
        drafts.map { $0.macro(registry: registry) }
    }

    /// Issues per draft; a draft with none is absent. As a last line of defence the converted macros
    /// go through `MacroValidator` itself, so a rule the draft checks missed still shows up (on the
    /// first draft the validator names, if the draft checks found nothing for it).
    public static func issues(in drafts: [MacroDraft], registry: ActionRegistry = ActionRegistry()) -> [UUID: [DraftIssue]] {
        var result: [UUID: [DraftIssue]] = [:]
        for draft in drafts {
            let found = draft.issues(among: drafts, registry: registry)
            if !found.isEmpty { result[draft.id] = found }
        }
        if result.isEmpty {
            do {
                try MacroValidator.validate(macros(from: drafts, registry: registry), registry: registry)
            } catch {
                if let first = drafts.first {
                    result[first.id] = [DraftIssue(message: "\(error)")]
                }
            }
        }
        return result
    }

    public static func isValid(_ drafts: [MacroDraft], registry: ActionRegistry = ActionRegistry()) -> Bool {
        issues(in: drafts, registry: registry).isEmpty
    }
}
