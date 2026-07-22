import Cocoa
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    weak var runnerManager: BackendRunnerManager?
    weak var catalogService: ModelCatalogService?
    weak var appSettings: AppSettings?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Crash-safety (localmgr-853.6): if a prior LocalMgr session was
        // force-quit/crashed while an engine was running, that engine is
        // orphaned (holding a port/VRAM with no supervisor). Detect and reap it
        // at launch, before any new engine is spawned.
        Task {
            let result = await CrashSafetyWatchdog.checkForOrphansAtLaunch()
            switch result {
            case .noOrphan:
                break
            case .terminatedOrphan(let m):
                AppLog.fault("Crash-safety: reaped orphaned engine '\(m.engineName)' (PID \(m.enginePID), model '\(m.modelName)', port \(m.port)) left by a prior LocalMgr session that did not exit cleanly", category: .runner)
            case .staleMarkerOnly(let m):
                AppLog.info("Crash-safety: cleared stale marker for '\(m.engineName)' (model '\(m.modelName)'); its process was already gone", category: .runner)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if appSettings?.terminateRunnersOnQuit ?? true {
            runnerManager?.stopCurrent()
        }
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
