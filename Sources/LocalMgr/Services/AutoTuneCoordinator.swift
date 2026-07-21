import Foundation
import Combine

/// Drives an on-demand "Auto-Tune (Measured)" run for the UI (localmgr-jhj.11)
/// and exposes observable progress + a concrete before/after result.
///
/// This is the glue between `ModelInspectorView`'s button and the
/// `EmpiricalTuner`/`EmpiricalTunerCache` engine: it resolves the binary and
/// hardware profile, runs the benchmark (or serves a cached winner), selects the
/// winner, and produces a `TuneOutcome` the view can render as a clear win or an
/// explicit "no improvement" message. It never silently applies a config that
/// would change the user's context length.
@MainActor
final class AutoTuneCoordinator: ObservableObject {

    enum Phase: Equatable {
        case idle
        case running(String)
        case done
        case unsupported(String)
        case failed(String)
    }

    /// The result of a completed tuning run, framed as a before/after comparison.
    struct TuneOutcome: Equatable {
        let modelName: String
        let contextLength: Int
        /// tok/s of the heuristic-default candidate (the "before").
        let baselineTPS: Double
        let baselineLabel: String
        /// tok/s of the selected winning candidate (the "after").
        let winnerTPS: Double
        let winnerLabel: String
        /// Whether the winner is a real improvement over the heuristic baseline.
        let improved: Bool
        /// Percentage improvement (winner vs baseline), may be ~0 or negative.
        let improvementPercent: Double
        let servedFromCache: Bool

        /// A user-facing headline for the result.
        var headline: String {
            if servedFromCache {
                return "Loaded a previously measured tuning result for this model + hardware."
            }
            if improved {
                return String(format: "Measured a %.0f%% speedup: %@ beats the heuristic default.", improvementPercent, winnerLabel as NSString)
            }
            return "No measured configuration beat the heuristic default. Keeping current settings."
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var outcome: TuneOutcome?

    /// Runs (or loads a cached) empirical tune for `model`. Safe to call from a
    /// button action; updates `phase`/`outcome` as it progresses.
    func runTune(for model: ModelItem, contextLength: Int) async {
        outcome = nil

        guard EmpiricalTuner.isTunable(model.engineType) else {
            phase = .unsupported("Auto-Tune (Measured) is not available for \(model.engineType.rawValue).")
            return
        }

        guard let binaryPath = EngineProbe.resolveBinaryPath(name: model.engineType.defaultBinaryName) else {
            phase = .failed("Could not find \(model.engineType.defaultBinaryName) to benchmark.")
            return
        }

        let profile = HardwareAutoTuner.detectProfile(
            physicalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory)
        )
        let totalMemory = Int64(ProcessInfo.processInfo.physicalMemory)
        let key = EmpiricalTunerCache.cacheKey(
            chipTier: profile.chipTier,
            totalMemoryBytes: totalMemory,
            engineBinaryPath: binaryPath,
            modelPath: model.fileURL.path,
            contextLength: contextLength
        )

        // Serve a cached winner when one exists for this exact environment.
        // The cache load re-checks context length (guardrail), so a hit can
        // never change the user's current context setting.
        if let cached = EmpiricalTunerCache.load(key: key, expectedContextLength: contextLength) {
            phase = .running("Found a cached tuning result...")
            outcome = TuneOutcome(
                modelName: model.name,
                contextLength: contextLength,
                baselineTPS: cached.tokensPerSecond,
                baselineLabel: "cached",
                winnerTPS: cached.tokensPerSecond,
                winnerLabel: cached.label,
                improved: true,
                improvementPercent: 0,
                servedFromCache: true
            )
            phase = .done
            return
        }

        phase = .running("Benchmarking candidate configurations (this loads the model a few times)...")

        let report = await EmpiricalTuner.runBenchmark(
            engine: model.engineType,
            modelPath: model.fileURL.path,
            modelName: model.fileURL.lastPathComponent,
            binaryPath: binaryPath,
            profile: profile,
            contextLength: contextLength,
            log: { msg in
                AppLog.info(msg.trimmingCharacters(in: .whitespacesAndNewlines), category: .runner)
            }
        )

        // The heuristic-default baseline is the first (default-threads, -ngl 99)
        // candidate -- it mirrors today's static launch flags.
        let baseline = report.results.first(where: { $0.succeeded }) ?? report.results.first

        guard let winner = EmpiricalTunerCache.selectWinner(from: report.results) else {
            phase = .failed("No candidate produced a usable measurement. Keeping heuristic defaults.")
            return
        }

        let baseTPS = baseline?.tokensPerSecond ?? 0
        let improvementPct = baseTPS > 0 ? ((winner.tokensPerSecond - baseTPS) / baseTPS) * 100.0 : 0
        // Only treat as an improvement if the winner is a *different* config than
        // the baseline AND meaningfully faster (beyond the tie margin).
        let improved = winner.candidate != baseline?.candidate
            && winner.tokensPerSecond > baseTPS * (1.0 + EmpiricalTunerCache.tieMargin)

        // Persist the winner for this environment so re-tuning is instant.
        let config = EmpiricalTunerCache.TunedConfig(from: winner.candidate, tokensPerSecond: winner.tokensPerSecond)
        EmpiricalTunerCache.save(config, key: key)

        outcome = TuneOutcome(
            modelName: model.name,
            contextLength: contextLength,
            baselineTPS: baseTPS,
            baselineLabel: baseline?.candidate.label ?? "heuristic default",
            winnerTPS: winner.tokensPerSecond,
            winnerLabel: winner.candidate.label,
            improved: improved,
            improvementPercent: improvementPct,
            servedFromCache: false
        )
        phase = .done
    }
}
