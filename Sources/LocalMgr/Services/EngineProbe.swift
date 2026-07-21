import Foundation

/// Shared, side-effect-free helpers for locating engine binaries and probing
/// OpenAI-compatible engine HTTP endpoints. Extracted from
/// `BackendRunnerManager` (localmgr-jhj.9) so both the primary runner and the
/// empirical auto-tuner (`EmpiricalTuner`) use a single implementation of
/// binary resolution, health probing, and throughput measurement rather than
/// duplicating three subtly-different copies.
enum EngineProbe {

    // MARK: - Binary resolution

    /// The ordered set of directories in which LocalMgr looks for an engine
    /// binary, mirroring the historical search order used by
    /// `BackendRunnerManager.resolveBinaryPath`. Kept as a single source of
    /// truth so a newly-supported install location is picked up everywhere.
    static func searchPaths(for name: String) -> [String] {
        [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            NSHomeDirectory() + "/Library/Application Support/LocalMgr/Engines/\(name)",
            NSHomeDirectory() + "/.local/bin/\(name)",
            NSHomeDirectory() + "/.cargo/bin/\(name)",
            NSHomeDirectory() + "/.local/share/uv/tools/ai-edge-litert/bin/\(name)",
            NSHomeDirectory() + "/.local/share/uv/tools/mlx-lm/bin/\(name)"
        ]
    }

    /// Resolves the absolute path to an engine binary by name, probing the
    /// known install locations in order. `litert-lm` additionally falls back to
    /// `litert-benchmark`, preserving prior behavior. Returns `nil` if not found.
    static func resolveBinaryPath(name: String) -> String? {
        var namesToProbe = [name]
        if name == "litert-lm" {
            namesToProbe.append("litert-benchmark")
        }

        let fileManager = FileManager.default
        for n in namesToProbe {
            for path in searchPaths(for: n) where fileManager.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    // MARK: - Health probing

    /// Best-effort health probe: does a healthy OpenAI-compatible engine answer
    /// `GET /v1/models` with HTTP 200 on `port`? Any connection failure, non-200,
    /// or timeout returns `false`. `timeout` defaults to 1.5s (adoption probe);
    /// callers polling during startup may pass a shorter value.
    static func isHealthy(port: Int, timeout: TimeInterval = 1.5) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                return true
            }
        } catch {
            // No listener / connection refused / timeout -> not healthy.
        }
        return false
    }

    // MARK: - Throughput measurement

    /// Result of a single completion measurement against an engine endpoint.
    struct CompletionMeasurement {
        let succeeded: Bool
        let completionTokens: Int
        let durationMs: Double
        let sampleText: String

        /// Tokens per second over the whole request, or 0 when the measurement
        /// failed or produced no measurable output.
        var tokensPerSecond: Double {
            guard succeeded, durationMs > 0, completionTokens > 0 else { return 0 }
            return Double(completionTokens) / (durationMs / 1000.0)
        }
    }

    /// Extracts the completion-token count from an OpenAI-compatible response
    /// body, falling back to a `bytes/4` estimate when `usage.completion_tokens`
    /// is absent -- identical to the estimate used by `LocalAPIGateway`.
    static func extractCompletionTokens(from data: Data) -> Int {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let usage = json["usage"] as? [String: Any],
           let tokens = usage["completion_tokens"] as? Int {
            return tokens
        }
        return max(1, data.count / 4)
    }

    /// Extracts a short textual sample from an OpenAI-compatible chat response,
    /// used only for the sanity gate ("did it produce coherent, non-empty
    /// output?"). Returns an empty string when nothing usable was found.
    /// Extracts a short textual sample from an OpenAI-compatible chat response,
    /// used only for the sanity gate ("did it produce coherent, non-empty
    /// output?"). Returns an empty string when nothing usable was found.
    ///
    /// Also honors `reasoning_content`: reasoning models (e.g. Gemma "thinking"
    /// variants) can spend a short `max_tokens` budget entirely on reasoning and
    /// return an empty `content` -- that is still coherent generated output and
    /// must pass the sanity gate, not be treated as a failed candidate. (Caught
    /// live during jhj.11 benchmarking: gemma-4-E2B filled 128 tokens of
    /// reasoning_content with empty content, which previously failed selection.)
    static func extractSampleText(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first else {
            return ""
        }
        if let msg = first["message"] as? [String: Any] {
            if let content = msg["content"] as? String, !content.isEmpty { return content }
            if let contentArr = msg["content"] as? [[String: Any]] {
                let joined = contentArr.compactMap { $0["text"] as? String }.joined(separator: " ")
                if !joined.isEmpty { return joined }
            }
            if let reasoning = msg["reasoning_content"] as? String, !reasoning.isEmpty { return reasoning }
        }
        if let text = first["text"] as? String { return text }
        return ""
    }

    /// Sends a single non-streaming chat completion to the engine on `port` and
    /// measures wall-clock throughput. Never throws -- failures are reported as
    /// `succeeded == false` so a benchmark loop can score them as a sanity-gate
    /// failure rather than aborting.
    static func measureCompletion(
        port: Int,
        modelName: String,
        prompt: String,
        maxTokens: Int,
        requestTimeout: TimeInterval = 120.0
    ) async -> CompletionMeasurement {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else {
            return CompletionMeasurement(succeeded: false, completionTokens: 0, durationMs: 0, sampleText: "")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = requestTimeout
        let payload: [String: Any] = [
            "model": modelName,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": maxTokens,
            "stream": false
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let start = CFAbsoluteTimeGetCurrent()
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let durationMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 200 else {
                return CompletionMeasurement(succeeded: false, completionTokens: 0, durationMs: durationMs, sampleText: "")
            }
            let tokens = extractCompletionTokens(from: data)
            let sample = extractSampleText(from: data)
            return CompletionMeasurement(
                succeeded: true,
                completionTokens: tokens,
                durationMs: durationMs,
                sampleText: sample
            )
        } catch {
            let durationMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            return CompletionMeasurement(succeeded: false, completionTokens: 0, durationMs: durationMs, sampleText: "")
        }
    }
}
