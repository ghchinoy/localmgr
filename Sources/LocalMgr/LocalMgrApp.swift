import SwiftUI

@main
struct LocalMgrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var catalogService = ModelCatalogService()
    @StateObject private var runnerManager = BackendRunnerManager()
    @StateObject private var monitorService = SystemMonitorService()
    @StateObject private var readinessService = EngineReadinessService()
    @StateObject private var gateway = LocalAPIGateway()
    @StateObject private var appSettings = AppSettings()
    @StateObject private var downloader = HubDownloaderService()
    @StateObject private var hfClient = HuggingFaceAPIClient()

    var body: some Scene {
        WindowGroup {
            MainSplitView()
                .environmentObject(catalogService)
                .environmentObject(runnerManager)
                .environmentObject(monitorService)
                .environmentObject(readinessService)
                .environmentObject(gateway)
                .environmentObject(appSettings)
                .environmentObject(downloader)
                .environmentObject(hfClient)
                .frame(minWidth: 950, minHeight: 600)
                .onAppear {
                    appDelegate.runnerManager = runnerManager
                    appDelegate.catalogService = catalogService
                    runnerManager.configure(settings: appSettings)
                    monitorService.configure(runner: runnerManager)
                    gateway.configure(catalog: catalogService, runner: runnerManager, settings: appSettings)
                    if !catalogService.folders.contains(appSettings.resolvedDownloadURL) {
                        catalogService.addFolder(appSettings.resolvedDownloadURL)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("Add Local Folder...") {
                    catalogService.promptAddFolder()
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
            CommandMenu("Models") {
                Button("Start Active / Last Runner") {
                    if let lastID = runnerManager.lastRunModelID, let model = catalogService.models.first(where: { $0.id == lastID }) ?? runnerManager.activeModel {
                        runnerManager.startModel(model)
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(runnerManager.status == .running || runnerManager.status == .starting)

                Button("Stop Active Runner") {
                    runnerManager.stopCurrent()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(runnerManager.status != .running && runnerManager.status != .starting)

                Divider()

                Button("Discover Hub Models...") {
                    NotificationCenter.default.post(name: NSNotification.Name("OpenHubDiscovery"), object: nil)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appSettings)
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(catalogService)
                .environmentObject(runnerManager)
                .environmentObject(monitorService)
                .environmentObject(readinessService)
                .environmentObject(gateway)
                .environmentObject(appSettings)
                .environmentObject(downloader)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(monitorService.shortMemorySummary)
            }
        }
    }
}
