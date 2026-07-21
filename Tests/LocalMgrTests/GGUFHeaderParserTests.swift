import XCTest
@testable import LocalMgr

final class GGUFHeaderParserTests: XCTestCase {
    func testInspectGemma4() {
        let home = NSHomeDirectory()
        let gemmaPath = home + "/projects/gemma/gemma-4-E2B-it-Q4_K_M.gguf"
        let url = URL(fileURLWithPath: gemmaPath)
        
        guard FileManager.default.fileExists(atPath: gemmaPath) else {
            print("SKIPPING testInspectGemma4 because local model was not found at \(gemmaPath)")
            return
        }
        
        let meta = GGUFHeaderParser.inspect(url: url)
        XCTAssertTrue(meta.isValidGGUF, "Should parse as valid GGUF")
        XCTAssertEqual(meta.architectureMarker, "gemma4", "Should recognize architecture as gemma4")
        XCTAssertEqual(meta.contextLength, 131072, "Should parse context length from binary metadata")
        XCTAssertEqual(meta.layerCount, 35, "Should parse layer/block count from binary metadata")
        XCTAssertEqual(meta.headCountKV, 1, "Should parse head count KV from binary metadata")
        XCTAssertEqual(meta.embeddingLength, 1536, "Should parse embedding length from binary metadata")
    }

    func testInspectGemma2() {
        let home = NSHomeDirectory()
        let path = home + "/projects/gemmma/my-custom-model.gguf"
        let url = URL(fileURLWithPath: path)
        
        guard FileManager.default.fileExists(atPath: path) else {
            print("SKIPPING testInspectGemma2 because local model was not found at \(path)")
            return
        }
        
        let meta = GGUFHeaderParser.inspect(url: url)
        XCTAssertTrue(meta.isValidGGUF, "Should parse as valid GGUF")
        XCTAssertEqual(meta.architectureMarker, "gemma2", "Should recognize architecture as gemma2")
        XCTAssertEqual(meta.contextLength, 8192, "Should parse context length from binary metadata")
        XCTAssertEqual(meta.layerCount, 26, "Should parse layer/block count from binary metadata")
    }

    func testInspectNorthMiniCode() {
        let home = NSHomeDirectory()
        let path = home + "/projects/north-mini-code/models/gguf/North-Mini-Code-1.0-UD-Q4_K_M.gguf"
        let url = URL(fileURLWithPath: path)
        
        guard FileManager.default.fileExists(atPath: path) else {
            print("SKIPPING testInspectNorthMiniCode because local model was not found at \(path)")
            return
        }
        
        let meta = GGUFHeaderParser.inspect(url: url)
        XCTAssertTrue(meta.isValidGGUF, "Should parse as valid GGUF")
        XCTAssertEqual(meta.architectureMarker, "cohere2moe", "Should recognize architecture as cohere2moe")
        XCTAssertEqual(meta.contextLength, 500000, "Should parse context length from binary metadata")
        XCTAssertEqual(meta.layerCount, 49, "Should parse layer/block count from binary metadata")
        XCTAssertEqual(meta.headCountKV, 4, "Should parse head count KV from binary metadata")
        XCTAssertEqual(meta.embeddingLength, 2048, "Should parse embedding length from binary")
    }

    func testModelClassifierVerifiedArchitectures() {
        // gemma4 and cohere2moe should classify as verified
        let gemma4Classification = ModelCompatibilityClassifier.classifyGGUF(isValidGGUF: true, architectureMarker: "gemma4")
        XCTAssertEqual(gemma4Classification.tier, .verified, "Gemma 4 architecture must classify as verified")

        let cohere2moeClassification = ModelCompatibilityClassifier.classifyGGUF(isValidGGUF: true, architectureMarker: "cohere2moe")
        XCTAssertEqual(cohere2moeClassification.tier, .verified, "cohere2moe architecture must classify as verified")

        let unknownClassification = ModelCompatibilityClassifier.classifyGGUF(isValidGGUF: true, architectureMarker: "unrecognized_family")
        XCTAssertEqual(unknownClassification.tier, .recognizedUnverified, "Unrecognized but parseable architecture should be recognizedUnverified")
    }
}
