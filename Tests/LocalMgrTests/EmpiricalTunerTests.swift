import XCTest
@testable import LocalMgr

final class EmpiricalTunerTests: XCTestCase {

    private func makeProfile(pCores: Int, eCores: Int) -> ChipProfile {
        ChipProfile(
            rawModel: "Mac16,1",
            chipFamily: "Apple M4 Series",
            chipTier: .m4,
            recommendedGPULayers: 99,
            useFlashAttention: true,
            maxSafeContext: 16384,
            performanceCoreCount: pCores,
            efficiencyCoreCount: eCores,
            gpuCoreCount: nil,
            largeContextCapability: InferredCapability(value: true, confirmed: false)
        )
    }

    // MARK: - Tunability

    func testTunability() {
        XCTAssertTrue(EmpiricalTuner.isTunable(.llamaCpp))
        XCTAssertTrue(EmpiricalTuner.isTunable(.mlx))
        XCTAssertFalse(EmpiricalTuner.isTunable(.gemmaCpp))
        XCTAssertFalse(EmpiricalTuner.isTunable(.kokoro))
        XCTAssertFalse(EmpiricalTuner.isTunable(.liteRT))
    }

    // MARK: - Candidate generation

    func testLlamaCandidatesVaryPerfKnobs() {
        let profile = makeProfile(pCores: 10, eCores: 4)
        let candidates = EmpiricalTuner.generateCandidates(engine: .llamaCpp, profile: profile, contextLength: 8192)
        // Full matrix on a machine with P and E cores: 3 candidates.
        XCTAssertEqual(candidates.count, 3)
        // They must differ in thread count (a genuine perf knob).
        let threadSet = Set(candidates.map { $0.threadCount ?? -1 })
        XCTAssertTrue(threadSet.count >= 2, "candidates should vary thread count")
        // P-core candidate present.
        XCTAssertTrue(candidates.contains { $0.threadCount == 10 })
        // All-cores candidate present with larger batch.
        XCTAssertTrue(candidates.contains { $0.threadCount == 14 && $0.batchSize == 512 })
    }

    /// ACCEPTANCE-CRITICAL (localmgr-jhj.9): no candidate may vary the user's
    /// context length. Every candidate must carry the exact configured value.
    func testAllCandidatesHoldContextLengthFixed() {
        let profile = makeProfile(pCores: 8, eCores: 2)
        for ctx in [4096, 8192, 16384, 32768] {
            let candidates = EmpiricalTuner.generateCandidates(engine: .llamaCpp, profile: profile, contextLength: ctx)
            XCTAssertFalse(candidates.isEmpty)
            for c in candidates {
                XCTAssertEqual(c.contextLength, ctx, "candidate '\(c.label)' must keep ctx \(ctx)")
            }
        }
    }

    func testLlamaCandidatesDegradeGracefullyWithoutCoreInfo() {
        // When core counts are unavailable (0), only the default candidate.
        let profile = makeProfile(pCores: 0, eCores: 0)
        let candidates = EmpiricalTuner.generateCandidates(engine: .llamaCpp, profile: profile, contextLength: 8192)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.gpuLayers, 99)
        XCTAssertNil(candidates.first?.threadCount)
        XCTAssertEqual(candidates.first?.contextLength, 8192)
    }

    func testMLXBaselineOnly() {
        let profile = makeProfile(pCores: 10, eCores: 4)
        let candidates = EmpiricalTuner.generateCandidates(engine: .mlx, profile: profile, contextLength: 8192)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.label, "MLX baseline")
        XCTAssertEqual(candidates.first?.contextLength, 8192)
    }

    func testUnsupportedEngineNoCandidates() {
        let profile = makeProfile(pCores: 10, eCores: 4)
        XCTAssertTrue(EmpiricalTuner.generateCandidates(engine: .gemmaCpp, profile: profile, contextLength: 8192).isEmpty)
    }

    // MARK: - Argument building

    func testLlamaArgsPinContextAndPerfFlags() {
        let candidate = EmpiricalTuner.Candidate(
            label: "test", gpuLayers: 99, threadCount: 10, batchSize: 512, contextLength: 32768
        )
        let args = EmpiricalTuner.buildArgs(engine: .llamaCpp, modelPath: "/tmp/m.gguf", port: 21050, candidate: candidate)
        // Context length must be the candidate's exact value, right after -c.
        let cIdx = args.firstIndex(of: "-c")!
        XCTAssertEqual(args[cIdx + 1], "32768")
        // Perf knobs present.
        XCTAssertTrue(args.contains("-ngl"))
        XCTAssertTrue(args.contains("99"))
        XCTAssertTrue(args.contains("-t"))
        XCTAssertTrue(args.contains("10"))
        XCTAssertTrue(args.contains("--batch-size"))
        XCTAssertTrue(args.contains("512"))
        XCTAssertTrue(args.contains("--port"))
        XCTAssertTrue(args.contains("21050"))
    }

    func testLlamaArgsOmitOptionalFlagsWhenNil() {
        let candidate = EmpiricalTuner.Candidate(
            label: "default", gpuLayers: 99, threadCount: nil, batchSize: nil, contextLength: 8192
        )
        let args = EmpiricalTuner.buildArgs(engine: .llamaCpp, modelPath: "/tmp/m.gguf", port: 21050, candidate: candidate)
        XCTAssertFalse(args.contains("-t"))
        XCTAssertFalse(args.contains("--batch-size"))
        let cIdx = args.firstIndex(of: "-c")!
        XCTAssertEqual(args[cIdx + 1], "8192")
    }

    func testEphemeralPortInIsolatedRange() {
        for _ in 0..<50 {
            let p = EmpiricalTuner.ephemeralBenchmarkPort()
            XCTAssertTrue((21000...21999).contains(p))
        }
    }
}
