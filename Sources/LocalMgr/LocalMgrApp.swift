import SwiftUI

@main
struct LocalMgrApp: App {
    @StateObject private var catalogService = ModelCatalogService()
    @StateObject private var runnerManager = BackendRunnerManager()
    @StateObject private var monitorService = SystemMonitorService()
    @StateObject private var readinessService = EngineReadinessService()
    @StateObject private var gateway = LocalAPIGateway()
    @StateObject private var appSettings = AppSettings()

    var body: some Scene {
        WindowGroup {
            MainSplitView()
                .environmentObject(catalogService)
                .environmentObject(runnerManager)
                .environmentObject(monitorService)
                .environmentObject(readinessService)
                .environmentObject(gateway)
                .environmentObject(appSettings)
                .frame(minWidth: 950, minHeight: 600)
                .onAppear {
                    runnerManager.configure(settings: appSettings)
                    gateway.configure(catalog: catalogService, runner: runnerManager)
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
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(monitorService.shortMemorySummary)
            }
        }
    }
}
