import SwiftUI

struct MainSplitView: View {
    @EnvironmentObject var catalog: ModelCatalogService
    @EnvironmentObject var runner: BackendRunnerManager
    @EnvironmentObject var monitor: SystemMonitorService
    @EnvironmentObject var readiness: EngineReadinessService
    @EnvironmentObject var gateway: LocalAPIGateway
    @EnvironmentObject var downloader: HubDownloaderService
    @EnvironmentObject var hfClient: HuggingFaceAPIClient

    @State private var showHubSheet: Bool = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } content: {
            ModelListView()
        } detail: {
            if let selected = catalog.selectedModel {
                ModelInspectorView(model: selected)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "cpu.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Select a model from the list to inspect and run")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
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
                Button(action: { showHubSheet = true }) {
                    Label("Hub Discovery", systemImage: "globe")
                }
                .help("Discover and download models from Hugging Face Hub (Cmd+Shift+H)")
                .keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }
        .sheet(isPresented: $showHubSheet) {
            HubDiscoveryView()
        }
    }
}
