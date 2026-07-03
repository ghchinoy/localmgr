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
            }

            if let active = runner.activeModel {
                HStack {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
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
