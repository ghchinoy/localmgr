import SwiftUI

struct MainSplitView: View {
    @EnvironmentObject var catalog: ModelCatalogService
    @EnvironmentObject var runner: BackendRunnerManager
    @EnvironmentObject var monitor: SystemMonitorService
    @EnvironmentObject var readiness: EngineReadinessService
    @EnvironmentObject var gateway: LocalAPIGateway

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
    }
}
