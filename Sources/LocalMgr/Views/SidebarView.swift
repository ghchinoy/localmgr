import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var catalog: ModelCatalogService
    @EnvironmentObject var runner: BackendRunnerManager

    var body: some View {
        List {
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
        }
        .listStyle(.sidebar)
        .navigationTitle("LocalMgr")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { catalog.refreshCatalog() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh Vault Catalog")
            }
        }
    }
}
