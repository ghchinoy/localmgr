import Foundation
import Combine

struct EngineComponentStatus: Identifiable {
    let id = UUID()
    let engineType: EngineType
    var isInstalled: Bool
    var resolvedPath: String?
    var versionString: String?
    var installHint: String

    /// The individual `DiagnosticCheck`s backing this engine's readiness
    /// state -- currently a binary-discoverability check, with room to grow
    /// (e.g. a version-probe or "binary executes successfully" check) since
    /// each is independently a `DiagnosticCheck`.
    var checks: [DiagnosticCheck] = []
}

@MainActor
class EngineReadinessService: ObservableObject {
    @Published var statuses: [EngineType: EngineComponentStatus] = [:]
    @Published var hfInstalled: Bool = false
    @Published var hfPath: String?

    /// Every `DiagnosticCheck` currently known to this service (all engines
    /// plus the Hugging Face CLI check), flattened for consumption by a
    /// unified diagnostics surface (see `DiagnosticsView`).
    var allChecks: [DiagnosticCheck] {
        EngineType.allCases.flatMap { statuses[$0]?.checks ?? [] } + (hfCheck.map { [$0] } ?? [])
    }

    private var hfCheck: DiagnosticCheck?

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

            let checkID = "engine.\(engine.rawValue).binaryPresent"
            let expected = "\(engine.defaultBinaryName) discoverable on PATH or in a known LocalMgr install directory"
            let installCommand = installCommand(for: engine)

            if let resolved = path {
                let check = DiagnosticCheck(
                    id: checkID,
                    status: .pass,
                    observed: "Found at \(resolved)",
                    expected: expected
                )
                statuses[engine] = EngineComponentStatus(
                    engineType: engine,
                    isInstalled: true,
                    resolvedPath: resolved,
                    versionString: "Available",
                    installHint: "Installed at \(resolved)",
                    checks: [check]
                )
            } else {
                let hint = installHint(for: engine)
                let check = DiagnosticCheck(
                    id: checkID,
                    status: .fail,
                    observed: "Not found on PATH or in any known install directory",
                    expected: expected,
                    fix: hint,
                    command: installCommand
                )
                statuses[engine] = EngineComponentStatus(
                    engineType: engine,
                    isInstalled: false,
                    resolvedPath: nil,
                    versionString: nil,
                    installHint: hint,
                    checks: [check]
                )
            }
        }

        if let path = findBinaryPath(name: "hf") ?? findBinaryPath(name: "huggingface-cli") {
            hfInstalled = true
            hfPath = path
            hfCheck = DiagnosticCheck(id: "hub.cli.present", status: .pass, observed: "Found at \(path)", expected: "hf or huggingface-cli discoverable on PATH")
        } else {
            hfInstalled = false
            hfPath = nil
            hfCheck = DiagnosticCheck(
                id: "hub.cli.present",
                status: .warn,
                observed: "Not found on PATH",
                expected: "hf or huggingface-cli discoverable on PATH",
                fix: "The Hugging Face CLI is optional (LocalMgr's built-in Hub Discovery downloader works without it), but installing it enables `huggingface-cli login` for gated-repo authentication.",
                command: "uv tool install huggingface_hub"
            )
        }
    }

    private func installHint(for engine: EngineType) -> String {
        switch engine {
        case .llamaCpp: return "Install via: brew install llama.cpp"
        case .mlx: return "Install via: pip install mlx-lm or uv tool install mlx-lm"
        case .kokoro: return "Install Kokoro server binary or place in App Support"
        case .gemmaCpp: return "Compile gemma.cpp binary and place in App Support"
        case .liteRT: return "Install via: uv tool install ai-edge-litert or pip install ai-edge-litert"
        }
    }

    private func installCommand(for engine: EngineType) -> String? {
        switch engine {
        case .llamaCpp: return "brew install llama.cpp"
        case .mlx: return "uv tool install mlx-lm"
        case .liteRT: return "uv tool install ai-edge-litert"
        case .kokoro, .gemmaCpp: return nil
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
