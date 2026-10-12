import AppCore
import AppKit
import StateStore
import SwiftUI

/// Settings: where the controller is, which display is the DualUp, how often to poll, the local API
/// port, launch at login and where the files are. The text fields are validated with the same
/// rules as `switchboardctl settings set`. Launch at login applies at once (it is the system's
/// setting, not a file); the rest applies on Save.
struct SettingsView: View {
    let model: AppModel

    @State private var draft = SettingsDraft(Settings())
    @State private var error: String?
    @State private var discoverMessage: String?
    @State private var isDiscovering = false
    @State private var justSaved = false

    private var isDirty: Bool { draft != SettingsDraft(model.settings) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                controllerSection
                monitorSection
                apiSection
                generalSection
                filesSection
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let error {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                } else if justSaved {
                    Text("Saved").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert") { revert() }
                    .disabled(!isDirty)
                Button("Save") { Task { await save() } }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty)
            }
            .padding(10)
        }
        .frame(width: 520)
        .onAppear(perform: revert)
    }

    // MARK: Sections

    private var controllerSection: some View {
        Section {
            HStack {
                TextField("Address", text: $draft.controllerURL, prompt: Text("http://192.168.1.50:80, or empty for none"))
                    .autocorrectionDisabled()
                Button(isDiscovering ? "Looking…" : "Discover") { Task { await discover() } }
                    .disabled(isDiscovering)
            }
            if let discoverMessage {
                Text(discoverMessage).font(.caption).foregroundStyle(.secondary)
            }
            if model.controllerURLComesFromEnvironment, let url = model.controllerURL {
                Text("\(Settings.controllerURLEnvironmentKey) is set and wins over this field: using \(url.absoluteString).")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("ESP32 controller")
        } footer: {
            Text("Discover looks for _switchboard._tcp on the local network. macOS asks for Local Network access the first time.")
        }
    }

    private var monitorSection: some View {
        Section("Monitor") {
            TextField("Display name contains", text: $draft.displayNameContains, prompt: Text("SDQHD"))
                .autocorrectionDisabled()
            TextField("Polling interval (seconds)", text: $draft.pollingIntervalSeconds, prompt: Text("30"))
        }
    }

    private var apiSection: some View {
        Section {
            TextField("Port", text: $draft.localAPIPort, prompt: Text("48600"))
        } header: {
            Text("Local API")
        } footer: {
            Text("The port the local API will listen on (127.0.0.1 only). The API and its token arrive in the next release.")
        }
    }

    private var generalSection: some View {
        Section("General") {
            Toggle("Launch at login", isOn: launchAtLoginBinding)
            if let message = model.launchAtLoginMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if model.launchAtLoginStatus == .requiresApproval {
                Button("Open Login Items settings…") { model.openLoginItemsSettings() }
            }
        }
    }

    private var filesSection: some View {
        Section("Files") {
            LabeledContent("Folder") {
                Text(model.supportDirectory.path(percentEncoded: false))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            Button("Reveal in Finder") { reveal() }
            Text("settings.json, macros.json")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLoginStatus.isOn },
            set: { enabled in Task { await model.setLaunchAtLogin(enabled) } }
        )
    }

    private func revert() {
        draft = SettingsDraft(model.settings)
        error = nil
        justSaved = false
    }

    private func save() async {
        do {
            let settings = try draft.settings(applyingTo: model.settings)
            try await model.saveSettings(settings)
            draft = SettingsDraft(model.settings)
            error = nil
            justSaved = true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            justSaved = false
        }
    }

    private func discover() async {
        isDiscovering = true
        discoverMessage = nil
        defer { isDiscovering = false }
        if let found = await model.discoverController() {
            draft.controllerURL = found.url.absoluteString
            discoverMessage = "Found \"\(found.name)\" at \(found.url.absoluteString). Press Save to use it."
        } else {
            discoverMessage = "No controller answered over mDNS. Check that it is on this network and that Local Network access is allowed for Switchboard."
        }
    }

    private func reveal() {
        let directory = model.supportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settingsFile = directory.appending(path: SettingsStore.fileName, directoryHint: .notDirectory)
        if FileManager.default.fileExists(atPath: settingsFile.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([settingsFile])
        } else {
            NSWorkspace.shared.open(directory)
        }
    }
}
