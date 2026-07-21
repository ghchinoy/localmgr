import Foundation
import CryptoKit

/// Winner-selection and hardware/software-hash-keyed caching for the empirical
/// auto-tuner (localmgr-jhj.10).
///
/// Selection prefers the fastest candidate that passes a basic sanity gate,
/// with a small tie-margin favoring the more conservative (lower-resource)
/// candidate when scores are close -- important because GPU-bound models show
/// near-identical tok/s across CPU-knob candidates (observed live in jhj.9:
/// 60.6/60.4/60.6), where blindly picking the numeric max would arbitrarily
/// favor a heavier config for noise-level gains.
///
/// The winning config is persisted keyed by a hash of the full environment
/// (chip tier + RAM + engine binary identity + model identity + context length),
/// so any change to hardware, engine binary, model, or the user's context-length
/// setting automatically invalidates the cache with no manual TTL.
///
/// CRITICAL invariant (localmgr-jhj.10): the cache key includes
/// `defaultContextLength`, and a cached config is only ever applied to a run at
/// the *same* context length. A cached winner can never silently change the
/// user's current context-length setting -- if the context differs, the key
/// differs, so it is a cache miss and a fresh benchmark is required.
enum EmpiricalTunerCache {

    /// The persisted winning configuration for one environment key.
    struct TunedConfig: Codable, Equatable {
        let label: String
        let gpuLayers: Int?
        let threadCount: Int?
        let batchSize: Int?
        /// The context length this config was measured at. Always equal to the
        /// key's context length; stored redundantly for human inspection and as
        /// a defensive re-check before adoption.
        let contextLength: Int
        let tokensPerSecond: Double
        let measuredAt: Date

        init(from candidate: EmpiricalTuner.Candidate, tokensPerSecond: Double, measuredAt: Date = Date()) {
            self.label = candidate.label
            self.gpuLayers = candidate.gpuLayers
            self.threadCount = candidate.threadCount
            self.batchSize = candidate.batchSize
            self.contextLength = candidate.contextLength
            self.tokensPerSecond = tokensPerSecond
            self.measuredAt = measuredAt
        }
    }

    // MARK: - Winner selection

    /// The fractional tie-margin within which two candidates are considered
    /// "tied" on throughput; the more conservative one wins a tie. 2% per spec.
    static let tieMargin = 0.02

    /// Scores how resource-heavy a candidate is (higher = heavier). Used only to
    /// break throughput ties toward the more conservative configuration.
    private static func resourceWeight(_ c: EmpiricalTuner.CandidateResult) -> Int {
        var w = 0
        w += (c.candidate.threadCount ?? 0)
        w += (c.candidate.batchSize ?? 0) / 128
        return w
    }

    /// Selects the winning candidate from a report, or `nil` if none passed the
    /// sanity gate (succeeded + non-empty coherent output + measurable tok/s).
    ///
    /// Rule: among gated candidates, take the highest tok/s; then, among all
    /// candidates within `tieMargin` of that best, pick the one with the lowest
    /// resource weight (most conservative). Ties in weight fall back to the
    /// original ordering (earlier candidates are the more default configs).
    static func selectWinner(from results: [EmpiricalTuner.CandidateResult]) -> EmpiricalTuner.CandidateResult? {
        let gated = results.filter { $0.succeeded && $0.tokensPerSecond > 0 && !$0.sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let best = gated.max(by: { $0.tokensPerSecond < $1.tokensPerSecond }) else {
            return nil
        }
        let threshold = best.tokensPerSecond * (1.0 - tieMargin)
        let contenders = gated.filter { $0.tokensPerSecond >= threshold }
        // Most conservative (lowest resource weight) among the near-best set.
        return contenders.min(by: { resourceWeight($0) < resourceWeight($1) })
    }

    // MARK: - Cache key

    /// Computes the environment cache key for a tuning run. Any change to chip
    /// tier, total RAM, engine binary identity (path+size+mtime), model identity
    /// (path+size+mtime), or context length yields a different key.
    static func cacheKey(
        chipTier: ChipTier,
        totalMemoryBytes: Int64,
        engineBinaryPath: String,
        modelPath: String,
        contextLength: Int
    ) -> String {
        let engineIdentity = fileIdentity(path: engineBinaryPath)
        let modelIdentity = fileIdentity(path: modelPath)
        let raw = [
            "tier=\(chipTier.rawValue)",
            "ram=\(totalMemoryBytes)",
            "engine=\(engineIdentity)",
            "model=\(modelIdentity)",
            "ctx=\(contextLength)"
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A stable per-file identity string (path + size + mtime). Changing the
    /// binary (e.g. upgrading llama-server via brew) changes size and/or mtime,
    /// invalidating the cache without needing to invoke `--version`.
    private static func fileIdentity(path: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int) ?? -1
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(path):\(size):\(Int(mtime))"
    }

    // MARK: - Persistence

    /// Directory where tuning results are cached.
    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("LocalMgr/Tuning", isDirectory: true)
    }

    private static func cacheFileURL(for key: String) -> URL {
        cacheDirectory.appendingPathComponent("\(key).json")
    }

    /// Persists a winning config under the given key. Best-effort: returns
    /// whether the write succeeded.
    @discardableResult
    static func save(_ config: TunedConfig, key: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(config)
            try data.write(to: cacheFileURL(for: key), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Loads a cached config for the key, or `nil` on miss.
    ///
    /// Guardrail: even on a hash hit, the loaded config's `contextLength` must
    /// match `expectedContextLength`; if it does not (which should be impossible
    /// since context length is part of the key, but is re-checked defensively),
    /// the entry is treated as a miss so a stale config can never silently change
    /// the user's context length.
    static func load(key: String, expectedContextLength: Int) -> TunedConfig? {
        let url = cacheFileURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let config = try? decoder.decode(TunedConfig.self, from: data) else { return nil }
        guard config.contextLength == expectedContextLength else { return nil }
        return config
    }

    /// Removes a cached entry (e.g. for tests or explicit re-tune).
    @discardableResult
    static func clear(key: String) -> Bool {
        (try? FileManager.default.removeItem(at: cacheFileURL(for: key))) != nil
    }
}
