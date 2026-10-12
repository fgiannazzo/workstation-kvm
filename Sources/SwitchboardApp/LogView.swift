import AppCore
import AppKit
import SwiftUI
import SwitchboardCore

/// The log, newest first, with a minimum-level filter and a button that copies the whole log.
struct LogView: View {
    let model: AppModel
    @State private var minimum: LogEntry.Level?

    var body: some View {
        let entries = LogPresentation.entries(model.log, minimum: minimum)
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $minimum) {
                    Text("All levels").tag(LogEntry.Level?.none)
                    ForEach(LogEntry.Level.allCases, id: \.self) { level in
                        Text(level == .debug ? "Debug and above" : "\(level.rawValue.capitalized) and above")
                            .tag(LogEntry.Level?.some(level))
                    }
                }
                .fixedSize()
                Spacer()
                Text("\(entries.count) of \(model.log.count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Copy all") { copyAll() }
                    .disabled(model.log.isEmpty)
            }
            .padding(10)
            Divider()

            if entries.isEmpty {
                VStack {
                    Spacer()
                    Text(model.log.isEmpty ? "Nothing logged yet." : "No entries at this level.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.date.formatted(date: .omitted, time: .standard))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(entry.level.rawValue)
                            .font(.caption.monospaced())
                            .foregroundStyle(color(entry.level))
                            .frame(width: 52, alignment: .leading)
                        Text(entry.message)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 360)
    }

    private func color(_ level: LogEntry.Level) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }

    /// The whole log, oldest first, as plain text.
    private func copyAll() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(LogPresentation.text(model.log), forType: .string)
    }
}
