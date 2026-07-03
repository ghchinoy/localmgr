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
            var path: String?
            if engine == .liteRT {
                path = findBinaryPath(name: "litert-lm") ?? findBinaryPath(name: "litert-benchmark")
            } else {
                path = findBinaryPath(name: engine.defaultBinaryName)
            }

            if let resolved = path {
                statuses[engine] = EngineComponentStatus(
                    engineType: engine,
                    isInstalled: true,
                    resolvedPath: resolved,
                    versionString: "Available",
                    installHint: "Installed at \(resolved)"
                )
            } else {
                let hint: String
                switch engine {
                case .llamaCpp: hint = "Install via: brew install llama.cpp"
                case .mlx: hint = "Install via: pip install mlx-lm or uv tool install mlx-lm"
                case .kokoro: hint = "Install Kokoro server binary or place in App Support"
                case .gemmaCpp: hint = "Compile gemma.cpp binary and place in App Support"
                case .liteRT: hint = "Install via: uv tool install ai-edge-litert or pip install ai-edge-litert"
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

        if let path = findBinaryPath(name: "hf") ?? findBinaryPath(name: "huggingface-cli") {
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
            NSHomeDirectory() + "/.local/bin/\(name)",
            NSHomeDirectory() + "/.cargo/bin/\(name)",
            NSHomeDirectory() + "/.local/share/uv/tools/ai-edge-litert/bin/\(name)",
            NSHomeDirectory() + "/.local/share/uv/tools/mlx-lm/bin/\(name)"
        ]

        for path in searchPaths {
            if fileManager.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }
}
