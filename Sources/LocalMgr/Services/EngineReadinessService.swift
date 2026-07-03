import Foundation
import Combine

struct EngineComponentStatus: Identifiable {
    let id = UUID()
    let engineType: EngineType
    var isInstalled: Bool
    var resolvedPath: String?
    var versionString: String?
    var installHint: String
}

@MainActor
class EngineReadinessService: ObservableObject {
    @Published var statuses: [EngineType: EngineComponentStatus] = [:]
    @Published var hfInstalled: Bool = false
    @Published var hfPath: String?

    init() {
        refreshReadiness()
    }

    func isReady(for engine: EngineType) -> Bool {
        statuses[engine]?.isInstalled ?? false
    }

    func status(for engine: EngineType) -> EngineComponentStatus {
        if let s = statuses[engine] {
            return s
        }
        return EngineComponentStatus(engineType: engine, isInstalled: false, installHint: "Check installation")
    }

    func refreshReadiness() {
        for engine in EngineType.allCases {
            let binaryName = engine.defaultBinaryName
            if let path = findBinaryPath(name: binaryName) {
                statuses[engine] = EngineComponentStatus(
                    engineType: engine,
                    isInstalled: true,
                    resolvedPath: path,
                    versionString: "Available",
                    installHint: "Installed at \(path)"
                )
            } else {
                let hint: String
                switch engine {
                case .llamaCpp: hint = "Install via: brew install llama.cpp"
                case .mlx: hint = "Install via: pip install mlx-lm"
                case .kokoro: hint = "Install Kokoro server binary or place in App Support"
                case .gemmaCpp: hint = "Compile gemma.cpp binary and place in App Support"
                }
                statuses[engine] = EngineComponentStatus(
                    engineType: engine,
                    isInstalled: false,
                    resolvedPath: nil,
                    versionString: nil,
                    installHint: hint
                )
            }
        }

        if let path = findBinaryPath(name: "hf" ) ?? findBinaryPath(name: "huggingface-cli") {
            hfInstalled = true
            hfPath = path
        } else {
            hfInstalled = false
            hfPath = nil
        }
    }

    private func findBinaryPath(name: String) -> String? {
        let fileManager = FileManager.default
        let searchPaths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            NSHomeDirectory() + "/Library/Application Support/LocalMgr/Engines/\(name)",
            NSHomeDirectory() + "/.local/bin/\(name)"
        ]

        for path in searchPaths {
            if fileManager.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }
}
