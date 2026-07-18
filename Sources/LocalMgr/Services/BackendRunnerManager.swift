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
    @Published var lastRunModelID: UUID?
    @Published var status: RunnerStatus = .stopped
    @Published var logOutput: String = ""
    @Published var port: Int = 8080
    @Published var lastPingResponse: String = ""
    @Published var isPinging: Bool = false
    @Published var totalRequestsServed: Int = 0
    @Published var totalTokensProcessed: Int = 0
    @Published var lastTTFTMilliseconds: Double = 0.0
    @Published var lastTokensPerSecond: Double = 0.0
    @Published var sessionStartTime: Date? = nil

    private var currentProcess: Process?
    private var pipe: Pipe?
    private weak var appSettings: AppSettings?
    private var lastActivityDate: Date = Date()
    private var idleTimer: Timer?

    /// Window within which a recorded activity timestamp is treated as "a
    /// request is plausibly still in flight" for the purposes of
    /// `MemoryPressureGuard`'s warning-level defer window. This is a
    /// heuristic (LocalMgr does not currently track precise request
    /// start/end boundaries per in-flight HTTP call) rather than an exact
    /// in-flight flag -- good enough to avoid stopping a runner in the
    /// middle of a burst of activity without adding request-level tracking.
    private static let recentActivityWindow: TimeInterval = 3.0

    /// Whether activity (a gateway request, a Quick Test Ping, etc.) was
    /// recorded recently enough that a runner should be treated as
    /// plausibly mid-request for `MemoryPressureGuard` warning-level defer
    /// purposes. See `recentActivityWindow`.
    var recentlyActive: Bool {
        Date().timeIntervalSince(lastActivityDate) < Self.recentActivityWindow
    }

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

    func sendTestPing(modelName: String, promptText: String) {
        guard status == .running else { return }
        isPinging = true
        lastPingResponse = "Sending 256-token verification ping to http://127.0.0.1:\(port)/v1/chat/completions..."
        recordActivity()

        let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "model": modelName,
            "messages": [["role": "user", "content": promptText]],
            "max_tokens": 256
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let httpResp = response as? HTTPURLResponse else {
                    await MainActor.run {
                        self.lastPingResponse = "Error: Did not receive valid HTTP response."
                        self.isPinging = false
                    }
                    return
                }

                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let first = choices.first {
                    var extractedText: String? = nil
                    if let msg = first["message"] as? [String: Any] {
                        var contentStr = (msg["content"] as? String) ?? ""
                        if contentStr.isEmpty, let contentArr = msg["content"] as? [[String: Any]] {
                            contentStr = contentArr.compactMap { $0["text"] as? String }.joined(separator: " ")
                        }
                        let reasoningStr = (msg["reasoning_content"] as? String) ?? ""

                        if !contentStr.isEmpty && !reasoningStr.isEmpty {
                            extractedText = "--- Thinking Process ---\n\(reasoningStr)\n\n--- Final Response ---\n\(contentStr)"
                        } else if !contentStr.isEmpty {
                            extractedText = contentStr
                        } else if !reasoningStr.isEmpty {
                            extractedText = "--- Thinking Process (Max tokens reached before answer) ---\n\(reasoningStr)"
                        }
                    } else if let textStr = first["text"] as? String {
                        extractedText = textStr
                    }

                    await MainActor.run {
                        if let text = extractedText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.lastPingResponse = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        } else {
                            self.lastPingResponse = "HTTP \(httpResp.statusCode) OK (Empty content returned): " + (String(data: data, encoding: .utf8) ?? "")
                        }
                        self.isPinging = false
                    }
                } else {
                    await MainActor.run {
                        self.lastPingResponse = "HTTP \(httpResp.statusCode): " + (String(data: data, encoding: .utf8) ?? "Unknown response")
                        self.isPinging = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.lastPingResponse = "Network error pinging model: \(error.localizedDescription)"
                    self.isPinging = false
                }
            }
        }
    }

    private func checkIdleTimeout() {
        guard status == .running, let settings = appSettings, settings.enableIdleUnload else { return }
        let elapsedMinutes = Date().timeIntervalSince(lastActivityDate) / 60.0
        if elapsedMinutes >= Double(settings.idleUnloadMinutes) {
            self.logOutput.append("\n[Idle Reclaimer]: Zero inference requests for \(settings.idleUnloadMinutes)m. Unloading model weights from VRAM to preserve system RAM.\n")
            AppLog.info("Idle reclaimer unloading '\(activeModel?.name ?? "unknown model")' after \(settings.idleUnloadMinutes)m of inactivity", category: .runner)
            stopCurrent()
        }
    }

    func startModel(_ model: ModelItem) {
        stopCurrent()
        recordActivity()
        self.activeModel = model
        self.lastRunModelID = model.id
        self.status = .starting
        self.sessionStartTime = Date()
        self.totalRequestsServed = 0
        self.totalTokensProcessed = 0
        self.lastTTFTMilliseconds = 0.0
        self.lastTokensPerSecond = 0.0
        self.logOutput = "\n--- Starting \(model.name) via \(model.engineType.rawValue) ---\n"
        self.lastPingResponse = ""

        let binaryName = model.engineType.defaultBinaryName
        guard let binaryPath = resolveBinaryPath(name: binaryName) else {
            self.status = .error
            self.logOutput.append("ERROR: Could not find binary '\(binaryName)' in system PATH or App Support.\n")
            AppLog.error("Could not find engine binary '\(binaryName)' for \(model.name) in system PATH or App Support", category: .runner)
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
                self.logOutput.append("[Hardware Auto-Tuner]: Detected \(profile.rawModel) (\(profile.chipFamily)). Injecting -ngl \(profile.recommendedGPULayers), --flash-attn on, ctx \(profile.maxSafeContext)\n")
                AppLog.info("Auto-tuned \(model.name) for \(profile.rawModel): -ngl \(profile.recommendedGPULayers), ctx \(profile.maxSafeContext)", category: .runner)
                args = ["-m", model.fileURL.path, "--port", "\(port)", "-ngl", "\(profile.recommendedGPULayers)", "-c", "\(min(defaultCtx, profile.maxSafeContext))", "--flash-attn", "on"]
            } else {
                self.logOutput.append("[Hardware Auto-Tuner]: Opted out in Settings. Using manual flags (-ngl 99, ctx \(defaultCtx))\n")
                args = ["-m", model.fileURL.path, "--port", "\(port)", "-ngl", "99", "-c", "\(defaultCtx)"]
            }
        case .mlx:
            if autoTuneEnabled {
                let profile = HardwareAutoTuner.detectProfile(physicalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory))
                self.logOutput.append("[Hardware Auto-Tuner]: Detected \(profile.rawModel) (\(profile.chipFamily)). Optimizing MLX server launch.\n")
                AppLog.info("Auto-tuned \(model.name) for \(profile.rawModel) (MLX)", category: .runner)
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

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let code = proc.terminationStatus
                if code != 0 {
                    self.status = .error
                    self.logOutput.append("\n[Runner process terminated unexpectedly with exit code \(code)]\n")
                    AppLog.error("Runner '\(model.name)' (\(binaryName)) terminated unexpectedly with exit code \(code)", category: .runner)
                } else {
                    self.status = .stopped
                    self.logOutput.append("\n[Runner process exited cleanly]\n")
                    AppLog.info("Runner '\(model.name)' (\(binaryName)) exited cleanly", category: .runner)
                }
                self.currentProcess = nil
                self.activeModel = nil
            }
        }

        do {
            try process.run()
            self.currentProcess = process
            AppLog.info("Launched \(binaryName) for '\(model.name)' on port \(port)", category: .runner)
            // Fallback status change if no specific string matched within 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if self.status == .starting && process.isRunning {
                    self.status = .running
                }
            }
        } catch {
            self.status = .error
            self.logOutput.append("Failed to launch process: \(error.localizedDescription)\n")
            AppLog.error("Failed to launch \(binaryName) for '\(model.name)': \(error.localizedDescription)", category: .runner)
        }
    }

    func stopCurrent() {
        if let process = currentProcess, process.isRunning {
            process.terminate()
            self.logOutput.append("\n--- Terminated runner process ---\n")
            AppLog.info("Manually terminated runner '\(activeModel?.name ?? "unknown model")'", category: .runner)
        }
        currentProcess = nil
        activeModel = nil
        status = .stopped
        sessionStartTime = nil
    }

    /// Stops the current runner in response to a `.softEvict`
    /// `MemoryPressureAction`, but only if it is not `recentlyActive` --
    /// i.e. never interrupts a runner that plausibly has a request in
    /// flight. Returns `true` if a runner was actually stopped.
    ///
    /// LocalMgr only ever supervises a single runner process at a time
    /// (`startModel` always calls `stopCurrent()` first), so "the least-
    /// recently-used idle runner" reduces to "the current runner, if idle".
    @discardableResult
    func stopIfIdle(reason: String) -> Bool {
        guard status == .running, !recentlyActive else { return false }
        logOutput.append("\n[Memory Pressure]: \(reason)\n")
        AppLog.info("MemoryPressureGuard soft-evicted idle runner '\(activeModel?.name ?? "unknown model")': \(reason)", category: .runner)
        stopCurrent()
        return true
    }

    /// Force-stops the current runner in response to a `.hardEvict`
    /// `MemoryPressureAction` (kernel-reported CRITICAL pressure).
    /// Unlike `stopIfIdle`, this acts unconditionally -- CRITICAL pressure
    /// means the system is at real risk of thrashing/freezing, which
    /// outweighs preserving one in-flight generation. This preserves the
    /// pre-existing "Emergency Pressure Release" behavior, now routed
    /// through `MemoryPressureGuard`'s edge-triggered/re-arm policy instead
    /// of firing unconditionally on every critical `DispatchSource` event.
    func stopForCriticalPressure(reason: String) {
        guard status == .running else { return }
        logOutput.append("\n[EMERGENCY PRESSURE RELEASE]: \(reason)\n")
        AppLog.fault("MemoryPressureGuard hard-evicted runner '\(activeModel?.name ?? "unknown model")' under critical pressure: \(reason)", category: .runner)
        stopCurrent()
    }

    func clearLogs() {
        self.logOutput = ""
    }

    func clearPingResponse() {
        self.lastPingResponse = ""
    }

    func recordTelemetry(ttftMs: Double, durationMs: Double, completionTokens: Int) {
        self.totalRequestsServed += 1
        self.totalTokensProcessed += completionTokens
        if ttftMs > 0 { self.lastTTFTMilliseconds = ttftMs }
        if durationMs > 0 && completionTokens > 0 {
            self.lastTokensPerSecond = Double(completionTokens) / (durationMs / 1000.0)
        }
        recordActivity()
    }

    private func resolveBinaryPath(name: String) -> String? {
        var namesToProbe = [name]
        if name == "litert-lm" {
            namesToProbe.append("litert-benchmark")
        }

        let fileManager = FileManager.default
        for n in namesToProbe {
            let searchPaths = [
                "/opt/homebrew/bin/\(n)",
                "/usr/local/bin/\(n)",
                "/usr/bin/\(n)",
                NSHomeDirectory() + "/Library/Application Support/LocalMgr/Engines/\(n)",
                NSHomeDirectory() + "/.local/bin/\(n)",
                NSHomeDirectory() + "/.cargo/bin/\(n)",
                NSHomeDirectory() + "/.local/share/uv/tools/ai-edge-litert/bin/\(n)",
                NSHomeDirectory() + "/.local/share/uv/tools/mlx-lm/bin/\(n)"
            ]
            for path in searchPaths {
                if fileManager.fileExists(atPath: path) {
                    return path
                }
            }
        }
        return nil
    }
}
