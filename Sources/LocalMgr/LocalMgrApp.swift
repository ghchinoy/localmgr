import SwiftUI

@main
struct LocalMgrApp: App {
    @StateObject private var catalogService = ModelCatalogService()
    @StateObject private var runnerManager = BackendRunnerManager()
    @StateObject private var monitorService = SystemMonitorService()
    @StateObject private var readinessService = EngineReadinessService()
    @StateObject private var gateway = LocalAPIGateway()

    var body: some Scene {
        WindowGroup {
            MainSplitView()
                .environmentObject(catalogService)
                .environmentObject(runnerManager)
                .environmentObject(monitorService)
                .environmentObject(readinessService)
                .environmentObject(gateway)
                .frame(minWidth: 950, minHeight: 600)
                .onAppear {
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

        MenuBarExtra {
            MenuBarView()
                .environmentObject(catalogService)
                .environmentObject(runnerManager)
                .environmentObject(monitorService)
                .environmentObject(readinessService)
                .environmentObject(gateway)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(monitorService.shortMemorySummary)
            }
        }
    }
}
