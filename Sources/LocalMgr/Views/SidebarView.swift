import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var catalog: ModelCatalogService
    @EnvironmentObject var runner: BackendRunnerManager
    @EnvironmentObject var readiness: EngineReadinessService
    @EnvironmentObject var gateway: LocalAPIGateway
    @EnvironmentObject var downloader: HubDownloaderService

    private var recentlyUsedModels: [ModelItem] {
        let lastUsed = UserDefaults.standard.dictionary(forKey: "LocalMgrModelLastUsedDates") as? [String: Double] ?? [:]
        let activeModels = catalog.models.filter { lastUsed[$0.fileURL.path] != nil }
        return activeModels.sorted {
            let t1 = lastUsed[$0.fileURL.path] ?? 0
            let t2 = lastUsed[$1.fileURL.path] ?? 0
            return t1 > t2
        }
    }

    private var frequentlyUsedModels: [ModelItem] {
        let counts = UserDefaults.standard.dictionary(forKey: "LocalMgrModelUsageCounts") as? [String: Int] ?? [:]
        let activeModels = catalog.models.filter { (counts[$0.fileURL.path] ?? 0) > 0 }
        return activeModels.sorted {
            let c1 = counts[$0.fileURL.path] ?? 0
            let c2 = counts[$1.fileURL.path] ?? 0
            return c1 > c2
        }
    }

    private func sidebarModelRow(for model: ModelItem) -> some View {
        Button(action: { catalog.selectedModel = model }) {
            HStack(spacing: 8) {
                Image(systemName: model.engineType.iconName)
                    .font(.caption)
                    .foregroundColor(catalog.selectedModel?.id == model.id ? .accentColor : .secondary)
                    .frame(width: 16)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .font(.caption.bold())
                        .lineLimit(1)
                    Text("\(model.format.rawValue) • \(model.sizeFormatted)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if runner.activeModel?.id == model.id && runner.status == .running {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private func helpText(for status: EngineComponentStatus) -> String {
        var text = status.installHint
        if status.updateAvailable {
            let latest = status.latestVersion ?? ""
            text += " (Update Available: v\(latest))"
        }
        return text
    }

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
                        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
                        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "3"
                        Text("v\(version) (\(build)) • macOS Apple Silicon")
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
                if runner.status == .running && runner.lastTokensPerSecond > 0 {
                    Button(action: { NotificationCenter.default.post(name: NSNotification.Name("OpenOpsDashboard"), object: nil) }) {
                        HStack {
                            Text("⚡️ \(String(format: "%.1f", runner.lastTokensPerSecond)) tok/s")
                            Spacer()
                            Text("\(Int(runner.lastTTFTMilliseconds))ms TTFT")
                        }
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.accentColor)
                        .padding(4)
                        .background(Color.accentColor.opacity(0.12))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help("Click to open Enterprise Ops Telemetry Dashboard")
                }
                Divider().padding(.vertical, 2)
                Button(action: { NotificationCenter.default.post(name: NSNotification.Name("OpenOpsDashboard"), object: nil) }) {
                    Label("Open Ops Dashboard", systemImage: "chart.bar.doc.horizontal")
                        .font(.caption.bold())
                }
                .buttonStyle(.link)
            }

            if downloader.isDownloading || downloader.lastError != nil {
                Section(header: Text("Model Downloads")) {
                    if downloader.isDownloading {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(downloader.statusMessage)
                                .font(.caption2)
                                .foregroundColor(.accentColor)
                            ProgressView(value: downloader.progress)
                        }
                        .padding(.vertical, 2)
                    }
                    if let error = downloader.lastError {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                                .font(.caption2)
                            Text(error.humanSummary)
                                .font(.caption2)
                                .foregroundColor(.red)
                            Spacer()
                            Button(action: { downloader.lastError = nil }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section(header: Text("Recently Used")) {
                let list = recentlyUsedModels
                if list.isEmpty {
                    Text("No models run yet")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 2)
                } else {
                    ForEach(list.prefix(3)) { model in
                        sidebarModelRow(for: model)
                    }
                }
            }

            Section(header: Text("Frequently Used")) {
                let list = frequentlyUsedModels
                if list.isEmpty {
                    Text("No models run yet")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 2)
                } else {
                    ForEach(list.prefix(3)) { model in
                        sidebarModelRow(for: model)
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
                // Only enabled engines are shown here -- readiness.statuses
                // omits disabled engines entirely (see
                // EngineReadinessService.refreshReadiness()), so iterating
                // EngineType.allCases directly would incorrectly re-surface
                // a disabled engine as "Missing" (its safe-default fallback
                // status) rather than hiding it as intended.
                ForEach(EngineType.allCases.filter { readiness.statuses[$0] != nil }) { engine in
                    let st = readiness.status(for: engine)
                    HStack {
                        Circle()
                            .fill(st.isInstalled ? Color.green : Color.red)
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.rawValue)
                                .font(.caption)
                            if st.isInstalled, let v = st.installedVersion {
                                Text("v\(v)" + (st.updateAvailable ? " ⚠️" : ""))
                                    .font(.system(size: 9))
                                    .foregroundColor(st.updateAvailable ? .orange : .secondary)
                            }
                        }
                        Spacer()
                        Text(st.isInstalled ? "Ready" : "Missing")
                            .font(.caption2.bold())
                            .foregroundColor(st.isInstalled ? .green : .red)
                    }
                    .help(st.installHint + (st.updateAvailable ? " (Update Available: v\(st.latestVersion ?? ""))" : ""))
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
