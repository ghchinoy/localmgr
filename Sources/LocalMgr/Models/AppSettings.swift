import SwiftUI
import Combine

@MainActor
class AppSettings: ObservableObject {
    @AppStorage("enableHardwareAutoTuning") var enableHardwareAutoTuning: Bool = true
    @AppStorage("defaultContextLength") var defaultContextLength: Int = 8192
    @AppStorage("enableIdleUnload") var enableIdleUnload: Bool = true
    @AppStorage("idleUnloadMinutes") var idleUnloadMinutes: Int = 15
    @Published var gatewayPort: Int = UserDefaults.standard.integer(forKey: "gatewayPort") == 0 ? 4891 : UserDefaults.standard.integer(forKey: "gatewayPort") {
        didSet {
            UserDefaults.standard.set(gatewayPort, forKey: "gatewayPort")
        }
    }
    @AppStorage("customDownloadPath") var customDownloadPath: String = ""
    @AppStorage("terminateRunnersOnQuit") var terminateRunnersOnQuit: Bool = true

    // MARK: - Per-Engine Enable/Disable
    //
    // Keys are the Swift `EngineType` case names (e.g. "gemmaCpp"), not the
    // enum's display-string `rawValue` (e.g. "gemma.cpp") -- so a future
    // rename of the display string shown in the UI never silently resets a
    // user's saved toggle state. llama.cpp/MLX/LiteRT are mature,
    // actively-scanned engines and default on; Kokoro TTS and gemma.cpp
    // currently have no model-scanning path in `ModelCatalogService` (no
    // model file is ever classified with either engine type) and gemma.cpp
    // is an explicitly documented roadmap item (`localmgr-e3b`, tracking
    // upstream Gemma 4+ support) -- both default off so they don't appear
    // as permanently "Missing" in readiness/diagnostics surfaces for users
    // who never use them.
    @AppStorage("engineEnabled.llamaCpp") var engineEnabledLlamaCpp: Bool = true
    @AppStorage("engineEnabled.mlx") var engineEnabledMLX: Bool = true
    @AppStorage("engineEnabled.liteRT") var engineEnabledLiteRT: Bool = true
    @AppStorage("engineEnabled.kokoro") var engineEnabledKokoro: Bool = false
    @AppStorage("engineEnabled.gemmaCpp") var engineEnabledGemmaCpp: Bool = false

    /// Whether the given engine is currently enabled. Callers (Settings UI,
    /// `EngineReadinessService`, `BackendRunnerManager`) should always go
    /// through this helper rather than switching over the 5 stored
    /// properties themselves.
    func isEngineEnabled(_ engine: EngineType) -> Bool {
        switch engine {
        case .llamaCpp: return engineEnabledLlamaCpp
        case .mlx: return engineEnabledMLX
        case .liteRT: return engineEnabledLiteRT
        case .kokoro: return engineEnabledKokoro
        case .gemmaCpp: return engineEnabledGemmaCpp
        }
    }

    /// Sets the enabled state for the given engine. Paired with
    /// `isEngineEnabled(_:)` so the Settings UI can bind a generic
    /// `Toggle` per `EngineType.allCases` without a 5-way switch of its own.
    func setEngineEnabled(_ engine: EngineType, _ value: Bool) {
        switch engine {
        case .llamaCpp: engineEnabledLlamaCpp = value
        case .mlx: engineEnabledMLX = value
        case .liteRT: engineEnabledLiteRT = value
        case .kokoro: engineEnabledKokoro = value
        case .gemmaCpp: engineEnabledGemmaCpp = value
        }
    }

    var resolvedDownloadURL: URL {
        if !customDownloadPath.isEmpty {
            return URL(fileURLWithPath: customDownloadPath)
        }
        let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("LocalMgr/Models")
        try? FileManager.default.createDirectory(at: defaultURL, withIntermediateDirectories: true)
        return defaultURL
    }
}
