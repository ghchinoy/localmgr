import XCTest
@testable import LocalMgr

final class EmpiricalTunerCacheTests: XCTestCase {

    private func candidate(label: String, threads: Int?, batch: Int?, ctx: Int = 8192) -> EmpiricalTuner.Candidate {
        EmpiricalTuner.Candidate(label: label, gpuLayers: 99, threadCount: threads, batchSize: batch, contextLength: ctx)
    }

    private func result(_ c: EmpiricalTuner.Candidate, tps: Double, ok: Bool = true, sample: String = "answer") -> EmpiricalTuner.CandidateResult {
        EmpiricalTuner.CandidateResult(
            candidate: c, tokensPerSecond: tps, ttftMsApprox: 10, succeeded: ok, sampleText: sample, note: ok ? "ok" : "fail"
        )
    }

    // MARK: - Winner selection

    func testSelectsFastestWhenClearlyBest() {
        let a = result(candidate(label: "A", threads: nil, batch: nil), tps: 40)
        let b = result(candidate(label: "B", threads: 4, batch: nil), tps: 80)
        let c = result(candidate(label: "C", threads: 10, batch: 512), tps: 55)
        let winner = EmpiricalTunerCache.selectWinner(from: [a, b, c])
        XCTAssertEqual(winner?.candidate.label, "B")
    }

    /// Near-tie (within 2%): pick the more conservative (lower resource) config.
    func testTieMarginPrefersConservative() {
        // 60.6 vs 60.4 vs 60.6 -- the jhj.9 live scenario. All within 2%.
        let deflt = result(candidate(label: "default", threads: nil, batch: nil), tps: 60.6)
        let pcore = result(candidate(label: "P-cores 4t", threads: 4, batch: nil), tps: 60.4)
        let allc = result(candidate(label: "all 10t batch512", threads: 10, batch: 512), tps: 60.6)
        let winner = EmpiricalTunerCache.selectWinner(from: [deflt, pcore, allc])
        // "default" has resource weight 0 -> most conservative wins the tie.
        XCTAssertEqual(winner?.candidate.label, "default")
    }

    func testSanityGateExcludesFailedAndEmpty() {
        let failed = result(candidate(label: "failed", threads: nil, batch: nil), tps: 999, ok: false)
        let empty = result(candidate(label: "empty", threads: 4, batch: nil), tps: 500, sample: "   ")
        let good = result(candidate(label: "good", threads: 10, batch: nil), tps: 30)
        let winner = EmpiricalTunerCache.selectWinner(from: [failed, empty, good])
        XCTAssertEqual(winner?.candidate.label, "good")
    }

    func testNoWinnerWhenAllFail() {
        let a = result(candidate(label: "A", threads: nil, batch: nil), tps: 0, ok: false)
        let b = result(candidate(label: "B", threads: 4, batch: nil), tps: 0, ok: false)
        XCTAssertNil(EmpiricalTunerCache.selectWinner(from: [a, b]))
    }

    // MARK: - Cache key

    func testCacheKeyStableForSameInputs() {
        let k1 = EmpiricalTunerCache.cacheKey(chipTier: .m5, totalMemoryBytes: 34359738368, engineBinaryPath: "/opt/homebrew/bin/llama-server", modelPath: "/tmp/m.gguf", contextLength: 8192)
        let k2 = EmpiricalTunerCache.cacheKey(chipTier: .m5, totalMemoryBytes: 34359738368, engineBinaryPath: "/opt/homebrew/bin/llama-server", modelPath: "/tmp/m.gguf", contextLength: 8192)
        XCTAssertEqual(k1, k2)
        XCTAssertEqual(k1.count, 64) // SHA-256 hex
    }

    func testCacheKeyChangesWithContextLength() {
        let k1 = EmpiricalTunerCache.cacheKey(chipTier: .m5, totalMemoryBytes: 34359738368, engineBinaryPath: "/opt/homebrew/bin/llama-server", modelPath: "/tmp/m.gguf", contextLength: 8192)
        let k2 = EmpiricalTunerCache.cacheKey(chipTier: .m5, totalMemoryBytes: 34359738368, engineBinaryPath: "/opt/homebrew/bin/llama-server", modelPath: "/tmp/m.gguf", contextLength: 32768)
        XCTAssertNotEqual(k1, k2, "context length must be part of the key")
    }

    func testCacheKeyChangesWithChipAndRAM() {
        let base = EmpiricalTunerCache.cacheKey(chipTier: .m5, totalMemoryBytes: 34359738368, engineBinaryPath: "/x", modelPath: "/m", contextLength: 8192)
        let diffChip = EmpiricalTunerCache.cacheKey(chipTier: .m4, totalMemoryBytes: 34359738368, engineBinaryPath: "/x", modelPath: "/m", contextLength: 8192)
        let diffRAM = EmpiricalTunerCache.cacheKey(chipTier: .m5, totalMemoryBytes: 17179869184, engineBinaryPath: "/x", modelPath: "/m", contextLength: 8192)
        XCTAssertNotEqual(base, diffChip)
        XCTAssertNotEqual(base, diffRAM)
    }

    // MARK: - Persistence + guardrail

    func testSaveLoadRoundTrip() {
        let key = "test-roundtrip-\(UUID().uuidString)"
        defer { EmpiricalTunerCache.clear(key: key) }
        let cfg = EmpiricalTunerCache.TunedConfig(
            from: candidate(label: "winner", threads: 4, batch: nil, ctx: 8192), tokensPerSecond: 60.4
        )
        XCTAssertTrue(EmpiricalTunerCache.save(cfg, key: key))
        let loaded = EmpiricalTunerCache.load(key: key, expectedContextLength: 8192)
        XCTAssertEqual(loaded?.label, "winner")
        XCTAssertEqual(loaded?.threadCount, 4)
        XCTAssertEqual(loaded?.contextLength, 8192)
        XCTAssertEqual(loaded?.tokensPerSecond ?? 0, 60.4, accuracy: 0.001)
    }

    func testLoadMissReturnsNil() {
        XCTAssertNil(EmpiricalTunerCache.load(key: "definitely-missing-\(UUID().uuidString)", expectedContextLength: 8192))
    }

    /// GUARDRAIL: a cached entry whose context length differs from the current
    /// setting must be treated as a miss so it can never silently be adopted.
    func testLoadRejectsMismatchedContextLength() {
        let key = "test-ctxguard-\(UUID().uuidString)"
        defer { EmpiricalTunerCache.clear(key: key) }
        let cfg = EmpiricalTunerCache.TunedConfig(
            from: candidate(label: "w", threads: 4, batch: nil, ctx: 16384), tokensPerSecond: 50
        )
        XCTAssertTrue(EmpiricalTunerCache.save(cfg, key: key))
        // Loading with a different expected context must refuse the entry.
        XCTAssertNil(EmpiricalTunerCache.load(key: key, expectedContextLength: 8192))
        // Loading with the matching context succeeds.
        XCTAssertNotNil(EmpiricalTunerCache.load(key: key, expectedContextLength: 16384))
    }
}
