import SwiftUI

struct MainSplitView: View {
    @EnvironmentObject var catalog: ModelCatalogService
    @EnvironmentObject var runner: BackendRunnerManager
    @EnvironmentObject var monitor: SystemMonitorService
    @EnvironmentObject var readiness: EngineReadinessService
    @EnvironmentObject var gateway: LocalAPIGateway
    @EnvironmentObject var downloader: HubDownloaderService
    @EnvironmentObject var hfClient: HuggingFaceAPIClient
    @EnvironmentObject var telemetryStore: TelemetryStore

    @State private var showHubSheet: Bool = false
    @State private var showOpsDashboard: Bool = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } content: {
            ModelListView()
        } detail: {
            if let selected = catalog.selectedModel {
                ModelInspectorView(model: selected)
            } else {
                VStack(spacing: 20) {
                    let imgPath = Bundle.main.path(forResource: "AppIcon", ofType: "png") ?? Bundle.main.bundlePath.appending("/Contents/Resources/AppIcon.png")
                    if let nsImg = NSImage(contentsOfFile: imgPath) {
                        Image(nsImage: nsImg)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 120, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                            .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 6)
                    } else {
                        Image(systemName: "cpu.fill")
                            .font(.system(size: 64))
                            .foregroundColor(.secondary)
                    }
                    VStack(spacing: 6) {
                        Text("LocalMgr — AI Orchestrator")
                            .font(.title2.bold())
                        Text("Select a model from the sidebar to inspect weights, tune Apple Silicon flags, or start inference.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                    }
                }
                .padding()
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if downloader.isDownloading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("⬇ \(downloader.statusMessage) (\(downloader.speedString))")
                            .font(.caption2.bold())
                            .foregroundColor(.accentColor)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12))
                    .cornerRadius(6)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                HStack {
                    Button(action: { showOpsDashboard = true }) {
                        Label("Ops Dashboard", systemImage: "chart.bar.doc.horizontal")
                    }
                    .help("Enterprise Ops Telemetry Dashboard (Cmd+Shift+O)")
                    .keyboardShortcut("o", modifiers: [.command, .shift])

                    Button(action: { showHubSheet = true }) {
                        Label("Hub Discovery", systemImage: "globe")
                    }
                    .help("Discover and download models from Hugging Face Hub (Cmd+Shift+H)")
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                }
            }
        }
        .sheet(isPresented: $showHubSheet) {
            HubDiscoveryView()
        }
        .sheet(isPresented: $showOpsDashboard) {
            OpsDashboardView()
                .frame(minWidth: 820, minHeight: 560)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenHubDiscovery"))) { _ in
            showHubSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenOpsDashboard"))) { _ in
            showOpsDashboard = true
        }
        .alert("Download Failed", isPresented: Binding(
            get: { downloader.lastError != nil },
            set: { if !$0 { downloader.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { downloader.lastError = nil }
        } message: {
            Text(downloader.lastError ?? "")
        }
    }
}
