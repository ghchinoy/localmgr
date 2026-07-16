import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var catalog: ModelCatalogService
    @EnvironmentObject var runner: BackendRunnerManager
    @EnvironmentObject var monitor: SystemMonitorService
    @EnvironmentObject var readiness: EngineReadinessService
    @EnvironmentObject var gateway: LocalAPIGateway
    @EnvironmentObject var downloader: HubDownloaderService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LocalMgr System Status")
                .font(.headline)

            Divider()

            HStack {
                Text("RAM Used:")
                Spacer()
                Text(monitor.shortMemorySummary)
                    .font(.caption.monospacedDigit())
            }

            HStack {
                Text("Gateway:")
                Spacer()
                Text(gateway.isRunning ? "🟢 Port \(String(gateway.port))" : "🔴 Offline")
                    .font(.caption.monospacedDigit())
            }

            if downloader.isDownloading {
                Divider()
                HStack {
                    ProgressView().controlSize(.small)
                    Text("⬇ \(downloader.activeModelName ?? "Downloading") (\(downloader.speedString))")
                        .font(.caption2.bold())
                        .foregroundColor(.accentColor)
                        .lineLimit(1)
                }
            } else if let error = downloader.lastError {
                Divider()
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(3)
                    Spacer()
                    Button(action: { downloader.lastError = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let active = runner.activeModel {
                HStack {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        // (localmgr-b9v.10 / ACC-1): color-only status dots
                        // convey nothing to VoiceOver by default.
                        .accessibilityLabel("Runner status")
                        .accessibilityValue(runner.status.rawValue)
                    Text(active.name)
                        .lineLimit(1)
                    Spacer()
                    Button("Stop") {
                        runner.stopCurrent()
                    }
                }
            } else {
                Text("No active models")
                    .foregroundColor(.secondary)
            }

            Divider()

            Button("Open Main Window") {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                    break
                }
            }

            Button("Quit LocalMgr") {
                runner.stopCurrent()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 260)
    }
}
