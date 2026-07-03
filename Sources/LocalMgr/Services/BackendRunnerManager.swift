import Foundation
import Combine

enum RunnerStatus: String {
    case stopped = "Stopped"
    case starting = "Starting..."
    case running = "Running"
    case error = "Error"
}

@MainActor
class BackendRunnerManager: ObservableObject {
    @Published var activeModel: ModelItem?
    @Published var status: RunnerStatus = .stopped
    @Published var logOutput: String = ""
    @Published var port: Int = 8080

    private var currentProcess: Process?
    private var pipe: Pipe?
    private weak var appSettings: AppSettings?
    private var lastActivityDate: Date = Date()
    private var idleTimer: Timer?

    init() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkIdleTimeout()
            }
        }
    }

    func configure(settings: AppSettings) {
        self.appSettings = settings
    }

    func recordActivity() {
        self.lastActivityDate = Date()
    }

    private func checkIdleTimeout() {
        guard status == .running, let settings = appSettings, settings.enableIdleUnload else { return }
        let elapsedMinutes = Date().timeIntervalSince(lastActivityDate) / 60.0
        if elapsedMinutes >= Double(settings.idleUnloadMinutes) {
            self.logOutput.append("\n[Idle Reclaimer]: Zero inference requests for \(settings.idleUnloadMinutes)m. Unloading model weights from VRAM to preserve system RAM.\n")
            stopCurrent()
        }
    }

    func startModel(_ model: ModelItem) {
        stopCurrent()
        recordActivity()
        self.activeModel = model
        self.status = .starting
        self.logOutput.append("\n--- Starting \(model.name) via \(model.engineType.rawValue) ---\n")

        let binaryName = model.engineType.defaultBinaryName
        guard let binaryPath = resolveBinaryPath(name: binaryName) else {
            self.status = .error
            self.logOutput.append("ERROR: Could not find binary '\(binaryName)' in system PATH or App Support.\n")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)

        let autoTuneEnabled = appSettings?.enableHardwareAutoTuning ?? true
        let defaultCtx = appSettings?.defaultContextLength ?? 8192

        var args: [String] = []
        switch model.engineType {
        case .llamaCpp:
            if autoTuneEnabled {
                let profile = HardwareAutoTuner.detectProfile(physicalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory))
                self.logOutput.append("[Hardware Auto-Tuner]: Detected \(profile.rawModel) (\(profile.chipFamily)). Injecting -ngl \(profile.recommendedGPULayers), --flash-attn, ctx \(profile.maxSafeContext)\n")
                args = ["-m", model.fileURL.path, "--port", "\(port)", "-ngl", "\(profile.recommendedGPULayers)", "-c", "\(min(defaultCtx, profile.maxSafeContext))", "--flash-attn"]
            } else {
                self.logOutput.append("[Hardware Auto-Tuner]: Opted out in Settings. Using manual flags (-ngl 99, ctx \(defaultCtx))\n")
                args = ["-m", model.fileURL.path, "--port", "\(port)", "-ngl", "99", "-c", "\(defaultCtx)"]
            }
        case .mlx:
            if autoTuneEnabled {
                let profile = HardwareAutoTuner.detectProfile(physicalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory))
                self.logOutput.append("[Hardware Auto-Tuner]: Detected \(profile.rawModel) (\(profile.chipFamily)). Optimizing MLX server launch.\n")
            }
            args = ["--model", model.fileURL.path, "--port", "\(port)"]
        case .kokoro:
            args = ["--model", model.fileURL.path, "--port", "\(port)"]
        case .gemmaCpp:
            args = ["--tokenizer", model.fileURL.path, "--compressed_weights", model.fileURL.path]
        case .liteRT:
            args = ["--model_path", model.fileURL.path, "--port", "\(port)", "--backend", "metal"]
        }

        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GGML_METAL"] = "1"
        process.environment = env

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        self.pipe = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                Task { @MainActor [weak self] in
                    self?.logOutput.append(text)
                    if self?.status == .starting && (text.contains("HTTP server listening") || text.contains("running on http")) {
                        self?.status = .running
                    }
                }
            }
        }

        do {
            try process.run()
            self.currentProcess = process
            // Fallback status change if no specific string matched within 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if self.status == .starting && process.isRunning {
                    self.status = .running
                }
            }
        } catch {
            self.status = .error
            self.logOutput.append("Failed to launch process: \(error.localizedDescription)\n")
        }
    }

    func stopCurrent() {
        if let process = currentProcess, process.isRunning {
            process.terminate()
            self.logOutput.append("\n--- Terminated runner process ---\n")
        }
        currentProcess = nil
        activeModel = nil
        status = .stopped
    }

    private func resolveBinaryPath(name: String) -> String? {
        let commonPaths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            NSHomeDirectory() + "/Library/Application Support/LocalMgr/Engines/\(name)"
        ]
        for path in commonPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }
}
