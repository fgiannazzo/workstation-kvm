import Actions
import AppCore
import AppKit
import SwiftUI
import SwitchboardCore

/// The menu bar popover: state, controls, the run row, and the way to the other windows.
struct PopoverView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var notifyText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StateSection(model: model)
            Divider()
            ControlsSection(model: model, notifyText: $notifyText)
            Divider()
            RunRow(model: model)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 350)
    }

    private var footer: some View {
        HStack {
            Button("Macros…") { showWindow(WindowID.macros, using: openWindow) }
            Button("Settings…") { showWindow(WindowID.settings, using: openWindow) }
            Button("Log…") { showWindow(WindowID.log, using: openWindow) }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.link)
    }
}

// MARK: - State

private struct StateSection: View {
    let model: AppModel

    var body: some View {
        let state = model.state
        VStack(alignment: .leading, spacing: 8) {
            Text("State").font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                row("PBP", state.pbp.title)
                row("Main input", state.mainInput.title)
                row("USB port", state.usbPortTitle)
                row("Displays", state.displays.title)
                ForEach(DisplayID.allCases, id: \.self) { display in
                    GridRow {
                        Text(display.title).foregroundStyle(.secondary)
                        HDMIAssumption(model: model, display: display)
                    }
                }
            }

            HStack(spacing: 16) {
                ReachabilityDot(
                    name: "Controller",
                    isReachable: state.controllerReachable,
                    note: model.controllerURL == nil ? "not set" : nil
                )
                ReachabilityDot(name: "DualUp", isReachable: state.dualUpReachable, note: nil)
            }

            if let error = state.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let startupError = model.startupError {
                Text(startupError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TimelineView(.periodic(from: .now, by: 5)) { context in
                Text("Updated \(RelativeTime.text(for: state.updatedAt, now: context.date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

/// The OREI switches cannot be read, so the controller only assumes which input each display is on.
/// The menu corrects the assumption without pulsing anything (`hdmi.resync`).
private struct HDMIAssumption: View {
    let model: AppModel
    let display: DisplayID

    var body: some View {
        let assumed = model.state.hdmiInputTitle(for: display)
        HStack(spacing: 6) {
            Text(assumed.map { "\($0) (assumed)" } ?? "Unknown")
            Menu("Actually on…") {
                ForEach(1...2, id: \.self) { input in
                    Button("Actually on HDMI \(input)") {
                        Task { await model.resyncHDMI(display: display, input: input) }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.isBusy || model.controllerURL == nil)
            .help("The switch cannot be read. If the display is not on the input shown, say which it is on; nothing is switched.")
        }
    }
}

private struct ReachabilityDot: View {
    let name: String
    let isReachable: Bool
    let note: String?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isReachable ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(note.map { "\(name) (\($0))" } ?? name)
                .font(.callout)
                .foregroundStyle(isReachable ? .primary : .secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name) \(isReachable ? "reachable" : "not reachable")")
    }
}

// MARK: - Controls

private struct ControlsSection: View {
    let model: AppModel
    @Binding var notifyText: String

    private var hasController: Bool { model.controllerURL != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Controls").font(.headline)

            if !model.macros.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(model.macros) { macro in
                        Button(macro.name) {
                            Task { await model.run(id: macro.id) }
                        }
                        .help("Run \(macro.id): " + macro.steps.map(\.summary).joined(separator: " → "))
                    }
                }
            }
            if let error = model.macrosError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Button("PBP on") { Task { await model.run(.monitorPBPOn) } }
                Button("PBP off") { Task { await model.run(.monitorPBPOff) } }
                Button("Read monitor") { Task { await model.run(.monitorRead) } }
            }

            HStack(spacing: 6) {
                Button("Displays off") { Task { await model.run(.displaysOff) } }
                Button("Displays on") { Task { await model.run(.displaysOn) } }
            }
            .disabled(!model.canSwitchDisplays)
            .help(model.canSwitchDisplays
                ? "Disconnect or reconnect the physical displays through BetterDisplay"
                : "Needs BetterDisplay (Pro) in /Applications")

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("USB port") {
                    Picker("USB port", selection: usbBinding) {
                        ForEach(1...4, id: \.self) { Text("\($0)").tag(Optional($0)) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                ForEach(DisplayID.allCases, id: \.self) { display in
                    LabeledContent(display.title) {
                        Picker(display.title, selection: hdmiBinding(display)) {
                            ForEach(1...2, id: \.self) { Text("HDMI \($0)").tag(Optional($0)) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
            }
            .disabled(!hasController)
            if !hasController {
                Text("USB and HDMI need the ESP32 controller: set its address in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                TextField("Notification text", text: $notifyText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(sendNotification)
                Button("Notify", action: sendNotification)
                    .disabled(notifyText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .disabled(model.isBusy)
    }

    private func sendNotification() {
        let text = notifyText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        notifyText = ""
        Task { await model.run(.notify, parameters: ["text": .string(text)]) }
    }

    /// Shows the controller's USB port; choosing another one selects it.
    private var usbBinding: Binding<Int?> {
        Binding(
            get: { model.state.usbPort },
            set: { port in
                guard let port, port != model.state.usbPort else { return }
                Task { await model.run(.usbSelect, parameters: ["port": .int(port)]) }
            }
        )
    }

    /// Shows the assumed input of a display; choosing the other one pulses its switch.
    private func hdmiBinding(_ display: DisplayID) -> Binding<Int?> {
        Binding(
            get: { model.state.hdmiInput[display] },
            set: { input in
                guard let input, input != model.state.hdmiInput[display] else { return }
                Task {
                    await model.run(.hdmiSelect, parameters: ["display": .string(display.rawValue), "input": .int(input)])
                }
            }
        )
    }
}

// MARK: - Run row

private struct RunRow: View {
    let model: AppModel

    var body: some View {
        let progress = model.runProgress
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(progress.statusLine.isEmpty ? "No run yet" : progress.statusLine)
                    .font(.callout)
                    .foregroundStyle(progress.lastOutcome == .failed ? Color.red : Color.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if progress.isRunning, progress.stepCount > 1 {
                ProgressView(value: progress.fraction)
            }
            if progress.isRunning, !progress.lastMessage.isEmpty {
                Text(progress.lastMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}
