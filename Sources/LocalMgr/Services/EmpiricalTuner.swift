import Foundation

/// Empirical, measured-on-this-machine auto-tuner (localmgr-jhj.9).
///
/// Replaces `HardwareAutoTuner`'s static heuristic flags with real throughput
/// measurement: for a given model + engine it defines a small set of candidate
/// launch configurations that vary genuine *performance* knobs (GPU layers,
/// thread count, batch size), launches each as a fully isolated engine
/// subprocess on an ephemeral port, and measures real tok/s against a small
/// fixed prompt suite.
///
/// CRITICAL invariant (see acceptance notes on localmgr-jhj.9): candidates must
/// NEVER vary or override the user's `AppSettings.defaultContextLength`. Context
/// length is a user-controlled correctness setting (how much prompt a request
/// can hold), not a performance-tuning knob, and conflating the two previously
/// caused a real bug (an explicit 32768 setting silently capped to 16384). Every
/// candidate holds context length fixed at the user's configured value.
enum EmpiricalTuner {

    // MARK: - Candidate model

    /// A single candidate launch configuration. Only genuine performance knobs
    /// are tunable here; `contextLength` is carried (not tuned) purely so the
    /// generated args pin `-c` to the user's setting and so tests can assert the
    /// context-length invariant.
    struct Candidate: Equatable {
        let label: String
        /// GPU offload layers (`-ngl`). `nil` means "let the engine decide" (not
        /// used for llama.cpp candidates, which always specify it explicitly).
        let gpuLayers: Int?
        /// CPU thread count (`-t` / `--threads`). `nil` means "engine default".
        let threadCount: Int?
        /// Prompt/eval batch size (`--batch-size`). `nil` means "engine default".
        let batchSize: Int?
        /// User-configured context length, held FIXED across all candidates.
        let contextLength: Int
    }

    /// Whether empirical tuning is supported for the given engine. Only
    /// OpenAI-compatible HTTP engines with tunable launch flags are supported;
    /// gemma.cpp (no server mode) and TTS engines are not.
    static func isTunable(_ engine: EngineType) -> Bool {
        switch engine {
        case .llamaCpp, .mlx:
            return true
        case .kokoro, .gemmaCpp, .liteRT:
            return false
        }
    }

    /// Generates the candidate set for a model on the given hardware profile,
    /// holding context length fixed at `contextLength` (the user's setting).
    ///
    /// - llama.cpp: full matrix -- varies `-ngl` and thread count (and a larger
    ///   batch size on the higher-throughput candidate). On a machine with a
    ///   known P-core count, one candidate pins threads to P-cores (best for
    ///   prompt processing) and another uses P+E cores.
    /// - MLX: baseline-only for now (mlx_lm.server exposes few tunable perf
    ///   flags); richer MLX candidates are tracked as follow-up work.
    static func generateCandidates(
        engine: EngineType,
        profile: ChipProfile,
        contextLength: Int
    ) -> [Candidate] {
        switch engine {
        case .llamaCpp:
            let pCores = profile.performanceCoreCount > 0 ? profile.performanceCoreCount : 0
            let eCores = profile.efficiencyCoreCount > 0 ? profile.efficiencyCoreCount : 0
            let totalCores = pCores + eCores

            var candidates: [Candidate] = []

            // Candidate A: full GPU offload, engine-default threads, default batch.
            // This is closest to today's static heuristic (-ngl 99).
            candidates.append(Candidate(
                label: "Full GPU offload (default threads)",
                gpuLayers: 99,
                threadCount: nil,
                batchSize: nil,
                contextLength: contextLength
            ))

            // Candidate B: full GPU offload, threads pinned to P-cores. On Apple
            // Silicon, P-core-only threading often reduces contention for the
            // CPU-bound tokenization/prompt-processing path.
            if pCores > 0 {
                candidates.append(Candidate(
                    label: "Full GPU offload (P-cores only: \(pCores)t)",
                    gpuLayers: 99,
                    threadCount: pCores,
                    batchSize: nil,
                    contextLength: contextLength
                ))
            }

            // Candidate C: full GPU offload, all cores + larger batch, favoring
            // throughput on longer prompts where batch size helps.
            if totalCores > pCores && totalCores > 0 {
                candidates.append(Candidate(
                    label: "Full GPU offload (all \(totalCores)t, batch 512)",
                    gpuLayers: 99,
                    threadCount: totalCores,
                    batchSize: 512,
                    contextLength: contextLength
                ))
            }

            return candidates

        case .mlx:
            // Baseline-only: a single measured configuration mirroring the
            // current MLX launch. Richer candidates deferred (follow-up bead).
            return [Candidate(
                label: "MLX baseline",
                gpuLayers: nil,
                threadCount: nil,
                batchSize: nil,
                contextLength: contextLength
            )]

        case .kokoro, .gemmaCpp, .liteRT:
            return []
        }
    }

    /// Builds the process argument list for a candidate, targeting `port`.
    /// Context length is always emitted from `candidate.contextLength` (never
    /// recomputed) so the user's setting is preserved verbatim.
    static func buildArgs(
        engine: EngineType,
        modelPath: String,
        port: Int,
        candidate: Candidate
    ) -> [String] {
        switch engine {
        case .llamaCpp:
            var args = ["-m", modelPath, "--port", "\(port)", "-c", "\(candidate.contextLength)"]
            if let ngl = candidate.gpuLayers { args += ["-ngl", "\(ngl)"] }
            if let threads = candidate.threadCount { args += ["-t", "\(threads)"] }
            if let batch = candidate.batchSize { args += ["--batch-size", "\(batch)"] }
            args += ["--flash-attn", "on"]
            return args
        case .mlx:
            return ["--model", modelPath, "--port", "\(port)"]
        case .kokoro, .gemmaCpp, .liteRT:
            return []
        }
    }

    // MARK: - Measurement

    /// The measured outcome of benchmarking one candidate.
    struct CandidateResult {
        let candidate: Candidate
        let tokensPerSecond: Double
        let ttftMsApprox: Double
        let succeeded: Bool
        let sampleText: String
        let note: String
    }

    /// Overall tuning report for a model+engine run.
    struct TuneReport {
        let engine: EngineType
        let modelName: String
        let contextLength: Int
        let results: [CandidateResult]
    }

    /// A small fixed prompt suite used for measurement. Kept short and
    /// deterministic so runs are quick and comparable across candidates.
    static let promptSuite: [String] = [
        "Write a haiku about the ocean.",
        "List three prime numbers greater than ten.",
        "Explain what a semaphore is in one sentence."
    ]

    /// The per-prompt completion cap used during measurement.
    static let maxTokensPerPrompt = 128

    /// Chooses an ephemeral loopback port for an isolated benchmark subprocess,
    /// deliberately away from the default runner ports to avoid collisions with
    /// the primary/adopted runner.
    static func ephemeralBenchmarkPort() -> Int {
        return Int.random(in: 21000...21999)
    }

    /// Runs the full candidate benchmark for a model. Launches each candidate in
    /// isolation (via `SubprocessWatchdog`-guarded processes on an ephemeral
    /// port), measures throughput over the prompt suite, tears the candidate
    /// down, and settles before the next one. Never throws -- failed candidates
    /// are recorded with `succeeded == false`.
    ///
    /// `binaryPath` and `profile` are injected so this can be driven from the UI
    /// (which already has hardware detection) and exercised in isolation.
    static func runBenchmark(
        engine: EngineType,
        modelPath: String,
        modelName: String,
        binaryPath: String,
        profile: ChipProfile,
        contextLength: Int,
        settleSeconds: Double = 1.5,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> TuneReport {
        let candidates = generateCandidates(engine: engine, profile: profile, contextLength: contextLength)
        var results: [CandidateResult] = []

        for candidate in candidates {
            log("[Tuner]: Benchmarking candidate '\(candidate.label)' (ctx fixed at \(candidate.contextLength))...\n")
            let port = ephemeralBenchmarkPort()
            let result = await benchmarkCandidate(
                engine: engine,
                modelPath: modelPath,
                modelName: modelName,
                binaryPath: binaryPath,
                port: port,
                candidate: candidate,
                log: log
            )
            results.append(result)
            if result.succeeded {
                log("[Tuner]: '\(candidate.label)' -> \(String(format: "%.1f", result.tokensPerSecond)) tok/s\n")
            } else {
                log("[Tuner]: '\(candidate.label)' failed: \(result.note)\n")
            }
            // Settle so the OS reclaims GPU/RAM before the next candidate.
            try? await Task.sleep(nanoseconds: UInt64(settleSeconds * 1_000_000_000))
        }

        return TuneReport(engine: engine, modelName: modelName, contextLength: contextLength, results: results)
    }

    /// Launches a single candidate, waits for health, measures the prompt suite,
    /// and tears it down. Isolated so a failure in one candidate cannot leak a
    /// process into the next.
    private static func benchmarkCandidate(
        engine: EngineType,
        modelPath: String,
        modelName: String,
        binaryPath: String,
        port: Int,
        candidate: Candidate,
        log: @escaping @Sendable (String) -> Void
    ) async -> CandidateResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = buildArgs(engine: engine, modelPath: modelPath, port: port, candidate: candidate)
        var env = ProcessInfo.processInfo.environment
        env["GGML_METAL"] = "1"
        process.environment = env
        // Discard child output; we only care about the HTTP measurement.
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return CandidateResult(
                candidate: candidate, tokensPerSecond: 0, ttftMsApprox: 0,
                succeeded: false, sampleText: "", note: "launch failed: \(error.localizedDescription)"
            )
        }

        // Ensure the subprocess is always torn down, even on early return.
        func teardown() async {
            let outcome = await SubprocessWatchdog.waitForExit(process: process, timeout: 5.0)
            log("[Tuner]: candidate '\(candidate.label)' teardown: \(outcome)\n")
        }

        // Wait for health (up to ~60s: model weights must load).
        var healthy = false
        for _ in 0..<240 {
            if process.isRunning == false { break }
            if await EngineProbe.isHealthy(port: port, timeout: 1.0) {
                healthy = true
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        guard healthy else {
            await teardown()
            return CandidateResult(
                candidate: candidate, tokensPerSecond: 0, ttftMsApprox: 0,
                succeeded: false, sampleText: "", note: "health check timed out"
            )
        }

        // Measure the prompt suite; aggregate tok/s over total tokens/total time.
        var totalTokens = 0
        var totalDurationMs = 0.0
        var firstSample = ""
        var anySucceeded = false
        for prompt in promptSuite {
            let m = await EngineProbe.measureCompletion(
                port: port, modelName: modelName, prompt: prompt, maxTokens: maxTokensPerPrompt
            )
            if m.succeeded {
                anySucceeded = true
                totalTokens += m.completionTokens
                totalDurationMs += m.durationMs
                if firstSample.isEmpty { firstSample = m.sampleText }
            }
        }

        await teardown()

        guard anySucceeded, totalDurationMs > 0, totalTokens > 0 else {
            return CandidateResult(
                candidate: candidate, tokensPerSecond: 0, ttftMsApprox: 0,
                succeeded: false, sampleText: firstSample, note: "no measurable completion"
            )
        }

        let aggregateTPS = Double(totalTokens) / (totalDurationMs / 1000.0)
        let approxTTFT = totalDurationMs / Double(promptSuite.count) * 0.2
        return CandidateResult(
            candidate: candidate,
            tokensPerSecond: aggregateTPS,
            ttftMsApprox: approxTTFT,
            succeeded: true,
            sampleText: firstSample,
            note: "ok"
        )
    }
}
