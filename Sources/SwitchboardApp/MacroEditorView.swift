import Actions
import AppCore
import SwiftUI
import SwitchboardCore

/// The macro editor: a list of macros on the left; on the right the selected macro's id, name,
/// ordered steps (each with the controls its action's parameters call for) and optional verify.
/// Nothing is written until Save, and Save only writes a macro list the store accepts.
struct MacroEditorView: View {
    let model: AppModel

    @State private var drafts: [MacroDraft] = []
    @State private var selection: UUID?
    @State private var saveError: String?
    @State private var justSaved = false

    private var issues: [UUID: [DraftIssue]] { MacroDraftSet.issues(in: drafts) }
    private var isDirty: Bool { MacroDraftSet.macros(from: drafts) != model.macros }
    private var canSave: Bool { model.macrosError == nil && isDirty && issues.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.macrosError {
                unreadableBanner(error)
                Divider()
            }
            HSplitView {
                sidebar
                    .frame(minWidth: 190, idealWidth: 210, maxWidth: 280)
                detail
                    .frame(minWidth: 460)
            }
            Divider()
            footer
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear(perform: load)
    }

    // MARK: Pieces

    private func unreadableBanner(_ error: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("macros.json could not be read, so nothing here can be saved.").bold()
                Text(error).font(.caption).textSelection(.enabled)
                Text("Fix the file by hand, then reload.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reload") {
                Task {
                    await model.reloadMacros()
                    load()
                }
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.08))
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(drafts) { draft in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(draft.name.isEmpty ? "(no name)" : draft.name)
                        Text(draft.macroID.isEmpty ? "(no id)" : draft.macroID)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .tag(draft.id)
                    .badge(issues[draft.id] == nil ? 0 : (issues[draft.id]?.count ?? 0))
                }
                .onMove { source, destination in
                    drafts.move(fromOffsets: source, toOffset: destination)
                }
            }
            Divider()
            HStack(spacing: 4) {
                Button { add() } label: { Image(systemName: "plus") }
                    .help("New macro")
                Button { duplicate() } label: { Image(systemName: "plus.square.on.square") }
                    .help("Duplicate the selected macro")
                    .disabled(selectedIndex == nil)
                Button { remove() } label: { Image(systemName: "minus") }
                    .help("Remove the selected macro")
                    .disabled(selectedIndex == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selection, let binding = binding(for: id) {
            MacroDraftForm(model: model, draft: binding, issues: issues[id] ?? [])
        } else {
            VStack {
                Spacer()
                Text(drafts.isEmpty ? "No macros. Add one with +." : "Select a macro.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            if let saveError {
                Text(saveError).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else if justSaved {
                Text("Saved to macros.json").font(.callout).foregroundStyle(.secondary)
            } else if !issues.isEmpty {
                Text("Fix the marked macros to save.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revert") { load() }
                .disabled(!isDirty)
            Button("Save") { Task { await save() } }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
        }
        .padding(10)
    }

    // MARK: Actions

    private var selectedIndex: Int? {
        selection.flatMap { id in drafts.firstIndex { $0.id == id } }
    }

    private func binding(for id: UUID) -> Binding<MacroDraft>? {
        guard drafts.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { drafts.first { $0.id == id } ?? MacroDraft(macroID: "", name: "") },
            set: { updated in
                if let index = drafts.firstIndex(where: { $0.id == id }) { drafts[index] = updated }
                justSaved = false
                saveError = nil
            }
        )
    }

    private func load() {
        drafts = model.macros.map(MacroDraft.init(macro:))
        selection = drafts.first?.id
        saveError = nil
        justSaved = false
    }

    private func add() {
        let draft = MacroDraft.new(among: drafts)
        drafts.append(draft)
        selection = draft.id
    }

    private func duplicate() {
        guard let index = selectedIndex else { return }
        let copy = drafts[index].duplicate(among: drafts)
        drafts.insert(copy, at: index + 1)
        selection = copy.id
    }

    private func remove() {
        guard let index = selectedIndex else { return }
        drafts.remove(at: index)
        selection = drafts.indices.contains(index) ? drafts[index].id : drafts.last?.id
    }

    private func save() async {
        do {
            try await model.saveMacros(MacroDraftSet.macros(from: drafts))
            saveError = nil
            justSaved = true
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            justSaved = false
        }
    }
}

// MARK: - One macro

private struct MacroDraftForm: View {
    let model: AppModel
    @Binding var draft: MacroDraft
    let issues: [DraftIssue]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Id").foregroundStyle(.secondary)
                        TextField("guest", text: $draft.macroID)
                            .font(.body.monospaced())
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Name").foregroundStyle(.secondary)
                        TextField("Guest", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                Text("Run it from the popover, a Stream Deck key (switchboard://run/\(draft.macroID.isEmpty ? "{id}" : draft.macroID)) or `switchboardctl run`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                stepsSection
                verifySection

                if !issues.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                            Label(issue.description, systemImage: "exclamationmark.circle")
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    // MARK: Steps

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Steps").font(.headline)
            Text("Run in order. The macro stops at the first step that fails; an unverified monitor write counts as a failure.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(draft.steps.enumerated()), id: \.element.id) { index, step in
                StepEditor(
                    model: model,
                    step: stepBinding(step.id),
                    number: index + 1,
                    isFirst: index == 0,
                    isLast: index == draft.steps.count - 1,
                    onMove: { offset in draft.moveStep(id: step.id, by: offset) },
                    onRemove: { draft.removeStep(id: step.id) }
                )
            }

            Menu {
                ForEach(model.actions) { descriptor in
                    Button(descriptor.title + (descriptor.signature.isEmpty ? "" : "  (\(descriptor.id.rawValue))")) {
                        draft.addStep(descriptor.id)
                    }
                }
            } label: {
                Label("Add step", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func stepBinding(_ id: UUID) -> Binding<StepDraft> {
        Binding(
            get: { draft.steps.first { $0.id == id } ?? StepDraft(action: .monitorRead) },
            set: { updated in
                if let index = draft.steps.firstIndex(where: { $0.id == id }) { draft.steps[index] = updated }
            }
        )
    }

    // MARK: Verify

    private var verifySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Verify after the last step").font(.headline)
            Text("Optional. Each field set here must match the state, or the macro fails.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("PBP").foregroundStyle(.secondary)
                    Picker("PBP", selection: $draft.verify.pbp) {
                        Text("Not checked").tag(PBPState?.none)
                        Text("On").tag(PBPState?.some(.on))
                        Text("Off").tag(PBPState?.some(.off))
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("Main input").foregroundStyle(.secondary)
                    Picker("Main input", selection: $draft.verify.mainInput) {
                        Text("Not checked").tag(MainInput?.none)
                        Text("HDMI 1").tag(MainInput?.some(.hdmi1))
                        Text("HDMI 2").tag(MainInput?.some(.hdmi2))
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("USB port").foregroundStyle(.secondary)
                    Picker("USB port", selection: $draft.verify.usbPort) {
                        Text("Not checked").tag(Int?.none)
                        ForEach(1...4, id: \.self) { Text("Port \($0)").tag(Int?.some($0)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                ForEach(DisplayID.allCases, id: \.self) { display in
                    GridRow {
                        Text(display.title).foregroundStyle(.secondary)
                        Picker(display.title, selection: hdmiVerifyBinding(display)) {
                            Text("Not checked").tag(Int?.none)
                            ForEach(1...2, id: \.self) { Text("HDMI \($0)").tag(Int?.some($0)) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
        }
    }

    private func hdmiVerifyBinding(_ display: DisplayID) -> Binding<Int?> {
        Binding(
            get: { draft.verify.hdmiInput[display] },
            set: { draft.verify.hdmiInput[display] = $0 }
        )
    }
}

// MARK: - One step

private struct StepEditor: View {
    let model: AppModel
    @Binding var step: StepDraft
    let number: Int
    let isFirst: Bool
    let isLast: Bool
    let onMove: (Int) -> Void
    let onRemove: () -> Void

    private var descriptor: ActionDescriptor {
        model.actions.first { $0.id == step.action } ?? ActionDescriptor(id: step.action, title: step.action.rawValue)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)

            Picker("Action", selection: actionBinding) {
                ForEach(model.actions) { Text($0.title).tag($0.id) }
            }
            .labelsHidden()
            .fixedSize()

            ForEach(descriptor.parameters, id: \.name) { parameter in
                ParameterEditor(parameter: parameter, text: valueBinding(parameter.name))
            }

            Spacer(minLength: 0)

            Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(isFirst)
                .help("Move up")
            Button { onMove(1) } label: { Image(systemName: "chevron.down") }
                .disabled(isLast)
                .help("Move down")
            Button(role: .destructive, action: onRemove) { Image(systemName: "trash") }
                .help("Remove step")
        }
        .buttonStyle(.borderless)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private var actionBinding: Binding<ActionID> {
        Binding(
            get: { step.action },
            set: { step.setAction($0) }
        )
    }

    private func valueBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { step.values[name] ?? "" },
            set: { step.values[name] = $0 }
        )
    }
}

/// The control a parameter calls for: a picker for a choice, a stepper for a bounded integer, a
/// text field for text.
private struct ParameterEditor: View {
    let parameter: ParameterDescriptor
    @Binding var text: String

    var body: some View {
        HStack(spacing: 4) {
            Text(parameter.name).font(.caption).foregroundStyle(.secondary)
            switch parameter.type {
            case .choice:
                Picker(parameter.name, selection: $text) {
                    ForEach(parameter.values ?? [], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            case .int:
                let low = parameter.min ?? 0
                let high = parameter.max ?? Int.max
                let step = (high - low) > 100 ? 100 : 1
                TextField(parameter.name, value: intBinding(default: low), format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                Stepper("", value: intBinding(default: low), in: low...high, step: step)
                    .labelsHidden()
            case .string:
                TextField(parameter.name, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140)
            }
        }
    }

    private func intBinding(default fallback: Int) -> Binding<Int> {
        Binding(
            get: { Int(text.trimmingCharacters(in: .whitespaces)) ?? fallback },
            set: { text = String($0) }
        )
    }
}
