import XCTest
@testable import LocalMgr

final class EngineProbeTests: XCTestCase {

    func testExtractCompletionTokensFromUsage() {
        let json = """
        {"choices":[{"message":{"content":"hi"}}],"usage":{"completion_tokens":42,"prompt_tokens":10}}
        """.data(using: .utf8)!
        XCTAssertEqual(EngineProbe.extractCompletionTokens(from: json), 42)
    }

    func testExtractCompletionTokensFallbackEstimate() {
        // No usage block -> bytes/4 estimate, clamped to >= 1.
        let json = """
        {"choices":[{"message":{"content":"some text here"}}]}
        """.data(using: .utf8)!
        let expected = max(1, json.count / 4)
        XCTAssertEqual(EngineProbe.extractCompletionTokens(from: json), expected)
    }

    func testExtractSampleTextFromMessageContent() {
        let json = """
        {"choices":[{"message":{"content":"hello world"}}]}
        """.data(using: .utf8)!
        XCTAssertEqual(EngineProbe.extractSampleText(from: json), "hello world")
    }

    func testExtractSampleTextFromContentArray() {
        let json = """
        {"choices":[{"message":{"content":[{"text":"part one"},{"text":"part two"}]}}]}
        """.data(using: .utf8)!
        XCTAssertEqual(EngineProbe.extractSampleText(from: json), "part one part two")
    }

    func testExtractSampleTextEmptyOnGarbage() {
        let json = "not json".data(using: .utf8)!
        XCTAssertEqual(EngineProbe.extractSampleText(from: json), "")
    }

    func testTokensPerSecondMath() {
        let m = EngineProbe.CompletionMeasurement(
            succeeded: true, completionTokens: 80, durationMs: 500.0, sampleText: "ok"
        )
        // 80 tokens / 0.5s = 160 tok/s
        XCTAssertEqual(m.tokensPerSecond, 160.0, accuracy: 0.0001)
    }

    func testTokensPerSecondZeroWhenFailed() {
        let failed = EngineProbe.CompletionMeasurement(
            succeeded: false, completionTokens: 80, durationMs: 500.0, sampleText: ""
        )
        XCTAssertEqual(failed.tokensPerSecond, 0.0)

        let noDuration = EngineProbe.CompletionMeasurement(
            succeeded: true, completionTokens: 80, durationMs: 0.0, sampleText: "ok"
        )
        XCTAssertEqual(noDuration.tokensPerSecond, 0.0)
    }

    func testResolveBinaryPathNilForNonexistent() {
        XCTAssertNil(EngineProbe.resolveBinaryPath(name: "definitely-not-a-real-engine-binary-xyz"))
    }

    func testSearchPathsIncludeKnownLocations() {
        let paths = EngineProbe.searchPaths(for: "llama-server")
        XCTAssertTrue(paths.contains("/opt/homebrew/bin/llama-server"))
        XCTAssertTrue(paths.contains("/usr/local/bin/llama-server"))
        XCTAssertTrue(paths.contains { $0.hasSuffix("/Library/Application Support/LocalMgr/Engines/llama-server") })
    }
}
