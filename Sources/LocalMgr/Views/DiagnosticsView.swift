import SwiftUI
import AppKit

/// In-app viewer for application-level diagnostic logs captured via `AppLog`
/// (unified logging + in-memory ring buffer, see `Logging.swift`).
///
/// This is intentionally separate from the model-runner "Live Logs" tab in
/// `ModelInspectorView`, which only shows spawned engine subprocess
/// (`llama-server`, `mlx_lm.server`, etc.) stdout/stderr -- this view shows
/// app-internal events (download failures, gateway bind errors, process
/// launch failures, auto-tuner decisions, etc).
struct DiagnosticsView: View {
    @ObservedObject private var diagnostics = AppDiagnostics.shared
    @Environment(\.dismiss) var dismiss

    @State private var selectedCategory: LogCategory?
    @State private var searchText: String = ""
    @State private var exportError: String?

    private var filteredEntries: [AppLogEntry] {
        var list = diagnostics.entries
        if let category = selectedCategory {
            list = list.filter { $0.category == category }
        }
        if !searchText.isEmpty {
            list = list.filter { $0.message.localizedCaseInsensitiveContains(searchText) }
        }
        return list.reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("App Diagnostics", systemImage: "stethoscope")
                    .font(.title2.bold())
                Spacer()
                Text("\(diagnostics.entries.count) entries")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            HStack {
                Picker("Category", selection: $selectedCategory) {
                    Text("All Categories").tag(LogCategory?.none)
                    ForEach(LogCategory.allCases) { category in
                        Text(category.rawValue).tag(LogCategory?.some(category))
                    }
                }
                .frame(width: 220)

                TextField("Filter messages...", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Spacer()

                Button(action: { diagnostics.clear() }) {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(diagnostics.entries.isEmpty)

                Button(action: copyToPasteboard) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(diagnostics.entries.isEmpty)

                Button(action: exportToFile) {
                    Label("Export...", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(diagnostics.entries.isEmpty)
            }
            .padding()

            if let exportError {
                Text(exportError)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }

            Divider()

            if filteredEntries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text(diagnostics.entries.isEmpty ? "No diagnostic events recorded yet this session." : "No entries match the current filter.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Also inspectable outside the app via Console.app, or:\nlog show --predicate 'subsystem == \"com.localmgr.mac\"' --last 1h")
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredEntries) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: entry.level.symbolName)
                            .foregroundColor(color(for: entry.level))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(entry.category.rawValue)
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15))
                                    .cornerRadius(4)
                                Text(entry.timestamp, style: .time)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            Text(entry.message)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(width: 760, height: 560)
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .blue
        case .error: return .orange
        case .fault: return .red
        }
    }

    private func diagnosticsText() -> String {
        let formatter = ISO8601DateFormatter()
        // Chronological order (oldest first) for exports/copies, regardless of the reversed on-screen list.
        return diagnostics.entries.map { entry in
            "[\(formatter.string(from: entry.timestamp))] [\(entry.level.rawValue.uppercased())] [\(entry.category.rawValue)] \(entry.message)"
        }.joined(separator: "\n")
    }

    private func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(diagnosticsText(), forType: .string)
        AppLog.info("Copied \(diagnostics.entries.count) diagnostic entries to the clipboard", category: .general)
    }

    private func exportToFile() {
        exportError = nil
        let panel = NSSavePanel()
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "LocalMgr-Diagnostics-\(timestamp).log"
        panel.allowedContentTypes = [.plainText]
        panel.message = "Export LocalMgr diagnostic log (attach this to a bug report)"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try diagnosticsText().write(to: url, atomically: true, encoding: .utf8)
            AppLog.info("Exported \(diagnostics.entries.count) diagnostic entries to \(url.lastPathComponent)", category: .general)
        } catch {
            exportError = "Failed to export diagnostics: \(error.localizedDescription)"
            AppLog.error("Failed to export diagnostics: \(error.localizedDescription)", category: .general)
        }
    }
}
