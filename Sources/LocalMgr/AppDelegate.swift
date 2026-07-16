import Cocoa
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    weak var runnerManager: BackendRunnerManager?
    weak var catalogService: ModelCatalogService?
    weak var appSettings: AppSettings?

    func applicationWillTerminate(_ notification: Notification) {
        if appSettings?.terminateRunnersOnQuit ?? true {
            runnerManager?.stopCurrent()
        }
        // (localmgr-b9v.7 / SEC-3): release all outstanding security-scoped
        // bookmark access grants on quit, pairing every
        // startAccessingSecurityScopedResource() call made this session.
        catalogService?.releaseAllFolderAccess()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        
        if let runner = runnerManager, runner.status == .running || runner.status == .starting, let model = runner.activeModel {
            let stopItem = NSMenuItem(title: "Stop \(model.name)", action: #selector(stopActiveRunner), keyEquivalent: "")
            stopItem.target = self
            menu.addItem(stopItem)
        } else if let runner = runnerManager, let lastID = runner.lastRunModelID, let model = catalogService?.folders.flatMap({ _ in catalogService?.models ?? [] }).first(where: { $0.id == lastID }) ?? runner.activeModel {
            let startItem = NSMenuItem(title: "Start \(model.name)", action: #selector(startLastRunner), keyEquivalent: "")
            startItem.target = self
            menu.addItem(startItem)
        } else {
            let infoItem = NSMenuItem(title: "No Active Engine Session", action: nil, keyEquivalent: "")
            infoItem.isEnabled = false
            menu.addItem(infoItem)
        }
        
        return menu
    }

    @objc private func stopActiveRunner() {
        runnerManager?.stopCurrent()
    }

    @objc private func startLastRunner() {
        if let runner = runnerManager, let lastID = runner.lastRunModelID, let model = catalogService?.models.first(where: { $0.id == lastID }) ?? runner.activeModel {
            runner.startModel(model)
        }
    }
}
