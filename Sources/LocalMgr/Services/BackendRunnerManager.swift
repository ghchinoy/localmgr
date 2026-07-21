import Foundation
import Combine

enum RunnerStatus: String {
    case stopped = "Stopped"
    case starting = "Starting..."
    case running = "Running"
    case error = "Error"
}

enum DaemonStartupPhase: Equatable {
    case launching
    case waitingForHealth
    case warming
    case ready
    case failed(String)
    
    var description: String {
        switch self {
        case .launching:
            return "Launching engine process..."
        case .waitingForHealth:
            return "Waiting for HTTP health check..."
        case .warming:
            return "Warming up model weights..."
        case .ready:
            return "Runner is ready!"
        case .failed(let err):
            return "Launch failed: \(err)"
        }
    }
}

@MainActor
class BackendRunnerManager: ObservableObject {
    @Published var state: RunnerState = RunnerState()
    @Published var startupPhase: DaemonStartupPhase? = nil

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

    private func syncState(_ newState: RunnerState) {
        self.state = newState
        self.status = newState.status.legacyStatus
        self.activeModel = newState.activeModel
        self.lastRunModelID = newState.lastRunModelID
        self.logOutput = newState.logOutput
        self.totalRequestsServed = newState.totalRequestsServed
        self.totalTokensProcessed = newState.totalTokensProcessed
        self.lastTTFTMilliseconds = newState.lastTTFTMilliseconds
        self.lastTokensPerSecond = newState.lastTokensPerSecond
        self.sessionStartTime = newState.sessionStartTime
    }

    private var currentProcess: Process?

    /// True when the currently-tracked runner was *adopted* -- i.e. a healthy
    /// engine was already listening on `port` at launch time (typically a
    /// process spawned by a prior LocalMgr session that outlived it after a
    /// crash/force-quit or dev rebuild) and we attached to it instead of
    /// spawning a duplicate. Adopted instances have no `currentProcess`
    /// (we do not own their lifecycle) and no captured stdout, so
    /// `stopCurrent()` must not attempt to force-kill them via the watchdog
    /// and log-tailing is unavailable for their history. See localmgr-jhj.8.
    private var adoptedInstance: Bool = false

    private var pipeDrain: SubprocessPipeDrain?
    private weak var appSettings: AppSettings?
    private weak var catalogService: ModelCatalogService?
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

    func configure(settings: AppSettings, catalog: ModelCatalogService) {
        self.appSettings = settings
        self.catalogService = catalog
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
        guard state.status == .running else { return }
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
        guard state.status == .running, let settings = appSettings, settings.enableIdleUnload else { return }
        let elapsedMinutes = Date().timeIntervalSince(lastActivityDate) / 60.0
        if elapsedMinutes >= Double(settings.idleUnloadMinutes) {
            let msg = "\n[Idle Reclaimer]: Zero inference requests for \(settings.idleUnloadMinutes)m. Unloading model weights from VRAM to preserve system RAM.\n"
            self.syncState(self.state.appendLog(msg))
            AppLog.info("Idle reclaimer unloading '\(activeModel?.name ?? "unknown model")' after \(settings.idleUnloadMinutes)m of inactivity", category: .runner)
            stopCurrent()
        }
    }

    /// Lightweight, best-effort probe: does a healthy engine already answer on
    /// `port`? Sends the same `GET /v1/models` request used by the post-launch
    /// health check and treats an HTTP 200 as "a healthy instance is already
    /// listening". Any connection failure, non-200, or timeout returns `false`.
    ///
    /// Note: OpenAI-compatible engines (`llama-server`, `mlx_lm.server`) do not
    /// reliably expose *which* model file backs the server via `/v1/models`
    /// (llama-server reports the `-m` path; mlx reports a repo id), so we do not
    /// attempt a strict model-identity match here -- a healthy OpenAI-compatible
    /// endpoint on the expected port is treated as adoptable. See localmgr-jhj.8.
    private func probeExistingHealthyInstance(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                return true
            }
        } catch {
            // No listener / connection refused / timeout -> not adoptable.
        }
        return false
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
            let error = LocalMgrError(
                message: "\(model.engineType.rawValue) is disabled in Settings.",
                kind: "engine-disabled",
                fix: "Enable it in Settings → Hardware & Engines, then try again."
            )
            self.syncState(self.state.markError(reason: error.humanSummary))
            AppLog.error(error.logSummary, category: .runner)
            return
        }

        stopCurrent()
        recordActivity()
        self.lastPingResponse = ""
        self.syncState(self.state.start(model: model))

        // Record the launch metrics for model tracking
        catalogService?.recordModelLaunch(model)

        // Adoption path (localmgr-jhj.8): before spawning a new engine process,
        // check whether a healthy OpenAI-compatible engine is already listening
        // on the expected port -- e.g. a runner spawned by a previous LocalMgr
        // session that outlived it (crash/force-quit/dev rebuild). If so, attach
        // to it rather than spawning a duplicate that would fail to bind the port
        // or leave an orphan. Only HTTP engines expose an adoptable health
        // endpoint; gemma.cpp has no server mode and is always spawned fresh.
        let supportsAdoption = (model.engineType == .llamaCpp || model.engineType == .mlx || model.engineType == .liteRT || model.engineType == .kokoro)
        if supportsAdoption {
            self.startupPhase = .waitingForHealth
            self.syncState(self.state.appendLog("[Adoption]: Checking for an existing healthy engine on port \(self.port) before spawning...\n"))
            let targetPort = self.port
            let currentModelID = model.id
            Task { [weak self] in
                guard let self = self else { return }
                let alreadyHealthy = await self.probeExistingHealthyInstance(port: targetPort)
                await MainActor.run {
                    // Bail if the user switched models while we were probing.
                    guard self.state.activeModel?.id == currentModelID else { return }
                    if alreadyHealthy {
                        self.adoptExistingInstance(model: model, port: targetPort)
                    } else {
                        self.spawnModel(model)
                    }
                }
            }
            return
        }

        spawnModel(model)
    }

    /// Attaches to an already-running, healthy engine on `port` instead of
    /// spawning a new process. No `currentProcess` is set (we do not own the
    /// process lifecycle) and no stdout is captured, so historical logs from
    /// before adoption are unavailable. See localmgr-jhj.8.
    private func adoptExistingInstance(model: ModelItem, port: Int) {
        self.adoptedInstance = true
        self.currentProcess = nil
        self.pipeDrain?.stop()
        self.pipeDrain = nil
        let msg = "[Adoption]: Found a healthy engine already listening on port \(port). Attaching to the existing instance instead of spawning a duplicate.\n[Adoption]: Note: this process was not started by this LocalMgr session -- its historical logs are unavailable and it will not be force-terminated on Stop.\n"
        self.startupPhase = .ready
        self.syncState(self.state.appendLog(msg).markRunning())
        AppLog.info("Adopted existing healthy '\(model.name)' engine on port \(port) (no duplicate spawned)", category: .runner)
    }

    private func spawnModel(_ model: ModelItem) {
        self.adoptedInstance = false
        let binaryName = model.engineType.defaultBinaryName
        guard let binaryPath = resolveBinaryPath(name: binaryName) else {
            self.syncState(self.state.markError(reason: "Could not find binary '\(binaryName)' in system PATH or App Support."))
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
                self.syncState(self.state.appendLog("[Hardware Auto-Tuner]: Detected \(profile.rawModel) (\(profile.chipFamily)). Injecting -ngl \(profile.recommendedGPULayers), --flash-attn on, ctx \(profile.maxSafeContext)\n"))
                AppLog.info("Auto-tuned \(model.name) for \(profile.rawModel): -ngl \(profile.recommendedGPULayers), ctx \(profile.maxSafeContext)", category: .runner)
                args = ["-m", model.fileURL.path, "--port", "\(port)", "-ngl", "\(profile.recommendedGPULayers)", "-c", "\(min(defaultCtx, profile.maxSafeContext))", "--flash-attn", "on"]
            } else {
                self.syncState(self.state.appendLog("[Hardware Auto-Tuner]: Opted out in Settings. Using manual flags (-ngl 99, ctx \(defaultCtx))\n"))
                args = ["-m", model.fileURL.path, "--port", "\(port)", "-ngl", "99", "-c", "\(defaultCtx)"]
            }
        case .mlx:
            if autoTuneEnabled {
                let profile = HardwareAutoTuner.detectProfile(physicalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory))
                self.syncState(self.state.appendLog("[Hardware Auto-Tuner]: Detected \(profile.rawModel) (\(profile.chipFamily)). Optimizing MLX server launch.\n"))
                AppLog.info("Auto-tuned \(model.name) for \(profile.rawModel) (MLX)", category: .runner)
            }
            args = ["--model", model.fileURL.path, "--port", "\(port)"]
        case .kokoro:
            args = ["--model", model.fileURL.path, "--port", "\(port)"]
        case .gemmaCpp:
            args = ["--tokenizer", model.fileURL.path, "--compressed_weights", model.fileURL.path]
        case .liteRT:
            let modelId = model.name.replacingOccurrences(of: " ", with: "-")
            self.syncState(self.state.appendLog("[LiteRT]: Pre-importing \(model.fileURL.path) as model ID: \(modelId)...\n"))
            
            let importProcess = Process()
            importProcess.executableURL = URL(fileURLWithPath: binaryPath)
            importProcess.arguments = ["import", model.fileURL.path, modelId]
            
            do {
                try importProcess.run()
                importProcess.waitUntilExit()
                if importProcess.terminationStatus == 0 {
                    self.syncState(self.state.appendLog("[LiteRT]: Successfully imported \(modelId)\n"))
                } else {
                    self.syncState(self.state.appendLog("[LiteRT]: Warning: import process exited with status \(importProcess.terminationStatus)\n"))
                }
            } catch {
                self.syncState(self.state.appendLog("[LiteRT]: Warning: Failed to execute import process: \(error.localizedDescription)\n"))
            }
            
            args = ["serve", "--port", "\(port)", "--host", "127.0.0.1"]
        }

        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GGML_METAL"] = "1"
        process.environment = env

        let drain = SubprocessPipeDrain { [weak self] text in
            guard let self = self else { return }
            Task { @MainActor in
                let nextState = self.state.appendLog(text)
                self.syncState(nextState)
            }
        }
        self.pipeDrain = drain
        drain.attach(to: process)

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let code = proc.terminationStatus
                if code != 0 {
                    AppLog.error("Runner '\(model.name)' (\(binaryName)) terminated unexpectedly with exit code \(code)", category: .runner)
                } else {
                    AppLog.info("Runner '\(model.name)' (\(binaryName)) exited cleanly", category: .runner)
                }
                
                if self.state.status == .starting || self.state.status == .warming {
                    self.startupPhase = .failed("Process exited with status \(code)")
                } else {
                    self.startupPhase = nil
                }
                
                self.syncState(self.state.terminate(exitCode: code))
                self.currentProcess = nil
                self.pipeDrain?.stop()
                self.pipeDrain = nil
            }
        }

        self.startupPhase = .launching

        do {
            try process.run()
            self.currentProcess = process
            AppLog.info("Launched \(binaryName) for '\(model.name)' on port \(port)", category: .runner)
            
            self.startupPhase = .waitingForHealth
            self.syncState(self.state.markStarting())

            let targetPort = self.port
            let currentModelID = model.id
            
            Task { [weak self] in
                let maxAttempts = 120
                var attempt = 0
                var ready = false
                
                while attempt < maxAttempts {
                    guard let self = self else { return }
                    
                    let isRunningAndUnchanged = await MainActor.run {
                        return self.currentProcess?.isRunning == true && self.state.activeModel?.id == currentModelID
                    }
                    
                    guard isRunningAndUnchanged else {
                        return
                    }
                    
                    let url = URL(string: "http://127.0.0.1:\(targetPort)/v1/models")!
                    var req = URLRequest(url: url)
                    req.httpMethod = "GET"
                    req.timeoutInterval = 1.0
                    
                    do {
                        let (_, response) = try await URLSession.shared.data(for: req)
                        if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                            ready = true
                            break
                        }
                    } catch {
                        // Ignore connection failures while starting up
                    }
                    
                    attempt += 1
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                
                guard let self = self else { return }
                await MainActor.run {
                    guard self.state.activeModel?.id == currentModelID && self.currentProcess != nil else { return }
                    
                    if ready {
                        self.startupPhase = .ready
                        self.syncState(self.state.markRunning())
                        AppLog.info("Model '\(model.name)' is fully ready after health check validation on port \(targetPort).", category: .runner)
                    } else {
                        let lastLogs = self.pipeDrain?.snapshot ?? "No logs captured."
                        self.startupPhase = .failed("Health check timed out on port \(targetPort)")
                        self.syncState(self.state.markError(reason: "Health check timed out on port \(targetPort). Last logs:\n\(lastLogs)"))
                        self.stopCurrent()
                    }
                }
            }
        } catch {
            self.startupPhase = .failed("Failed to launch process: \(error.localizedDescription)")
            self.syncState(self.state.markError(reason: "Failed to launch process: \(error.localizedDescription)"))
            AppLog.error("Failed to launch \(binaryName) for '\(model.name)': \(error.localizedDescription)", category: .runner)
        }
    }

    func stopCurrent() {
        var nextState = self.state.stop()
        if adoptedInstance {
            // We attached to a process we did not spawn (localmgr-jhj.8); we do
            // not own its lifecycle, so we detach rather than force-terminate it.
            nextState = nextState.appendLog("\n--- Detaching from adopted engine (not force-terminated -- LocalMgr did not spawn it) ---\n")
            AppLog.info("Detached from adopted runner '\(activeModel?.name ?? "unknown model")' without terminating it", category: .runner)
        } else if let process = currentProcess, process.isRunning {
            nextState = nextState.appendLog("\n--- Terminating runner process with watchdog (5s timeout) ---\n")
            AppLog.info("Terminating runner '\(activeModel?.name ?? "unknown model")' using watchdog...", category: .runner)
            
            Task {
                let outcome = await SubprocessWatchdog.waitForExit(process: process, timeout: 5.0)
                AppLog.info("Runner process watch complete: \(outcome)", category: .runner)
            }
        }
        self.adoptedInstance = false
        self.startupPhase = nil
        self.currentProcess = nil
        self.pipeDrain?.stop()
        self.pipeDrain = nil
        self.syncState(nextState)
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
        guard state.status == .running, !recentlyActive else { return false }
        AppLog.info("MemoryPressureGuard soft-evicted idle runner '\(activeModel?.name ?? "unknown model")': \(reason)", category: .runner)
        let msg = "\n[Memory Pressure]: \(reason)\n"
        self.syncState(self.state.appendLog(msg))
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
        guard state.status == .running else { return }
        AppLog.fault("MemoryPressureGuard hard-evicted runner '\(activeModel?.name ?? "unknown model")' under critical pressure: \(reason)", category: .runner)
        let msg = "\n[EMERGENCY PRESSURE RELEASE]: \(reason)\n"
        self.syncState(self.state.appendLog(msg))
        stopCurrent()
    }

    func clearLogs() {
        self.syncState(self.state.clearLogs())
    }

    func clearPingResponse() {
        self.lastPingResponse = ""
    }

    func recordTelemetry(ttftMs: Double, durationMs: Double, completionTokens: Int) {
        self.syncState(self.state.recordTelemetry(ttftMs: ttftMs, durationMs: durationMs, completionTokens: completionTokens))
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
