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

    /// Number of gateway requests (`/v1/chat/completions`, streaming or
    /// non-streaming) currently in flight against this runner. Incremented
    /// by `beginRequest()` when a request starts proxying to the upstream
    /// engine and decremented by `endRequest()` in every exit path
    /// (success, error, exception, upstream timeout).
    ///
    /// This replaces a prior rolling-timestamp heuristic (`recordActivity()`
    /// / a 3-second `recentActivityWindow`) that only recorded *when a
    /// request arrived*, not how long it ran -- any single request whose
    /// upstream processing exceeded 3 seconds (trivially true for
    /// large-context/tool-heavy coding-agent prompts) was incorrectly
    /// treated as "idle" by `MemoryPressureGuard`'s warning-level check,
    /// and could be killed mid-generation by `stopIfIdle`. See
    /// `localmgr-mtz`: confirmed live -- a real ~30K-token OpenCode request
    /// was killed by the memory-pressure guard 24+ seconds into prompt
    /// processing, well before it ever reached `recentActivityWindow`'s
    /// 3-second cutoff.
    private var inFlightRequestCount: Int = 0

    /// Whether at least one gateway request is currently in flight against
    /// this runner. Used by `stopIfIdle` to ensure `MemoryPressureGuard`
    /// never interrupts an active generation, regardless of how long it has
    /// been running (see `inFlightRequestCount`).
    var recentlyActive: Bool {
        inFlightRequestCount > 0
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

    /// Marks a moment of gateway activity for `checkIdleTimeout`'s
    /// idle-unload timer (`AppSettings.idleUnloadMinutes`). Distinct from
    /// in-flight request tracking (`beginRequest`/`endRequest`) -- this is
    /// only used to reset the "no requests for N minutes" unload countdown,
    /// not to guard against mid-request eviction.
    func recordActivity() {
        self.lastActivityDate = Date()
    }

    /// Marks the start of a gateway request against this runner. Must be
    /// paired with exactly one `endRequest()` call on every exit path
    /// (success, error, thrown exception, upstream timeout) so
    /// `inFlightRequestCount` never leaks upward and permanently blocks
    /// idle eviction.
    func beginRequest() {
        inFlightRequestCount += 1
    }

    /// Marks the end of a gateway request previously started via
    /// `beginRequest()`. Clamped at zero as a defensive measure against a
    /// mismatched begin/end pair.
    func endRequest() {
        inFlightRequestCount = max(0, inFlightRequestCount - 1)
    }

    func sendTestPing(modelName: String, promptText: String) {
        guard status == .running else { return }
        isPinging = true
        lastPingResponse = "Sending 256-token verification ping to http://127.0.0.1:\(port)/v1/chat/completions..."
        recordActivity()
        beginRequest()

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
                        self.endRequest()
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
                        self.endRequest()
                    }
                } else {
                    await MainActor.run {
                        self.lastPingResponse = "HTTP \(httpResp.statusCode): " + (String(data: data, encoding: .utf8) ?? "Unknown response")
                        self.isPinging = false
                        self.endRequest()
                    }
                }
            } catch {
                await MainActor.run {
                    self.lastPingResponse = "Network error pinging model: \(error.localizedDescription)"
                    self.isPinging = false
                    self.endRequest()
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
        // Refuse to launch a model whose engine has been disabled in
        // Settings -> Hardware & Engines (Kokoro/gemma.cpp default off).
        // Checked before stopCurrent() so a rejected request never tears
        // down an already-running, still-enabled model. Today no scan path
        // in ModelCatalogService can actually produce a ModelItem with
        // engineType .kokoro/.gemmaCpp (see localmgr-lvb epic description),
        // so this is defense-in-depth for whenever that changes, and for
        // any future manual/programmatic model construction.
        if let appSettings, !appSettings.isEngineEnabled(model.engineType) {
            self.status = .error
            let error = LocalMgrError(
                message: "\(model.engineType.rawValue) is disabled in Settings.",
                kind: "engine-disabled",
                fix: "Enable it in Settings → Hardware & Engines, then try again."
            )
            self.logOutput.append("\nERROR: \(error.humanSummary)\n")
            AppLog.error(error.logSummary, category: .runner)
            return
        }

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
