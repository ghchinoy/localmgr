import Cocoa
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    weak var runnerManager: BackendRunnerManager?
    weak var catalogService: ModelCatalogService?

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
