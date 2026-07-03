import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var catalog: ModelCatalogService
    @EnvironmentObject var runner: BackendRunnerManager
    @EnvironmentObject var readiness: EngineReadinessService
    @EnvironmentObject var gateway: LocalAPIGateway

    var body: some View {
        List {
            Section(header: Text("API Gateway (Port \(gateway.port))")) {
                HStack {
                    Circle()
                        .fill(gateway.isRunning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(gateway.isRunning ? "Online" : "Offline")
                        .font(.subheadline.bold())
                    Spacer()
                    Text("\(gateway.requestCount) reqs")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Text(gateway.lastLog)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Section(header: Text("Vault Locations")) {
                ForEach(catalog.folders, id: \.self) { url in
                    Label(url.lastPathComponent, systemImage: "folder.fill")
                        .help(url.path)
                }
                Button(action: { catalog.promptAddFolder() }) {
                    Label("Add Folder...", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }

            Section(header: Text("Active Runner")) {
                if let active = runner.activeModel {
                    HStack {
                        Circle()
                            .fill(runner.status == .running ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(active.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        Button(action: { runner.stopCurrent() }) {
                            Image(systemName: "stop.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text("No runner active")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            Section(header: Text("Component Readiness")) {
                ForEach(EngineType.allCases) { engine in
                    let st = readiness.status(for: engine)
                    HStack {
                        Circle()
                            .fill(st.isInstalled ? Color.green : Color.red)
                            .frame(width: 6, height: 6)
                        Text(engine.rawValue)
                            .font(.caption)
                        Spacer()
                        Text(st.isInstalled ? "Ready" : "Missing")
                            .font(.caption2.bold())
                            .foregroundColor(st.isInstalled ? .green : .red)
                    }
                    .help(st.installHint)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("LocalMgr")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { 
                    catalog.refreshCatalog()
                    readiness.refreshReadiness()
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh Vault Catalog & Component Status")
            }
        }
    }
}
