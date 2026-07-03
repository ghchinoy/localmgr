import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var catalog: ModelCatalogService
    @EnvironmentObject var runner: BackendRunnerManager
    @EnvironmentObject var readiness: EngineReadinessService
    @EnvironmentObject var gateway: LocalAPIGateway
    @EnvironmentObject var downloader: HubDownloaderService

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    let imgPath = Bundle.main.path(forResource: "AppIcon", ofType: "png") ?? Bundle.main.bundlePath.appending("/Contents/Resources/AppIcon.png")
                    if let nsImg = NSImage(contentsOfFile: imgPath) {
                        Image(nsImage: nsImg)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        Image(systemName: "cpu.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.accentColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LocalMgr")
                            .font(.headline.bold())
                        Text("v1.0.0 • macOS Apple Silicon")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section(header: Text("API Gateway (Port \(String(gateway.port)))")) {
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

            Section(header: Text("Curated Hugging Face Hub")) {
                if downloader.isDownloading {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(downloader.statusMessage)
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                        ProgressView(value: downloader.progress)
                    }
                    .padding(.vertical, 2)
                } else {
                    ForEach(downloader.curatedCatalog) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.caption)
                                Text("\(item.format.rawValue) • \(item.sizeFormatted)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(action: {
                                if let targetFolder = catalog.folders.first {
                                    downloader.downloadModel(item, targetFolder: targetFolder, catalog: catalog)
                                } else {
                                    catalog.promptAddFolder()
                                }
                            }) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(.plain)
                            .help("Download verified model with SHA-256 hash check")
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section(header: Text("Vault Locations")) {
                ForEach(catalog.folders, id: \.self) { url in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "folder.fill")
                            .foregroundColor(.accentColor)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent)
                                .font(.body)
                            Text(url.deletingLastPathComponent().path)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
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
                        HStack(spacing: 8) {
                            Circle()
                                .fill(runner.status == .running ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(active.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            catalog.selectedModel = active
                        }
                        .help("Click to inspect active runner details & live logs")

                        Button(action: { runner.stopCurrent() }) {
                            Image(systemName: "stop.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Stop active runner")
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
