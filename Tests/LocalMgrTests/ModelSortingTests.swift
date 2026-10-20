import XCTest
@testable import LocalMgr

@MainActor
final class ModelSortingTests: XCTestCase {
    func testModelLaunchRecording() {
        let catalog = ModelCatalogService()
        
        let testModel = ModelItem(
            name: "test-model-9hv",
            fileURL: URL(fileURLWithPath: "/tmp/models/test-model-9hv.gguf"),
            format: .gguf,
            sizeBytes: 1024,
            engineType: .llamaCpp
        )
        
        // Reset state before run
        var lastUsed = UserDefaults.standard.dictionary(forKey: "LocalMgrModelLastUsedDates") as? [String: Double] ?? [:]
        var counts = UserDefaults.standard.dictionary(forKey: "LocalMgrModelUsageCounts") as? [String: Int] ?? [:]
        lastUsed.removeValue(forKey: testModel.fileURL.path)
        counts.removeValue(forKey: testModel.fileURL.path)
        UserDefaults.standard.set(lastUsed, forKey: "LocalMgrModelLastUsedDates")
        UserDefaults.standard.set(counts, forKey: "LocalMgrModelUsageCounts")
        
        XCTAssertEqual(catalog.usageCount(for: testModel), 0, "Usage count should initially be 0")
        XCTAssertNil(catalog.lastUsedDescription(for: testModel), "Last used desc should initially be nil")
        
        catalog.recordModelLaunch(testModel)
        
        XCTAssertEqual(catalog.usageCount(for: testModel), 1, "Usage count should increment to 1")
        XCTAssertNotNil(catalog.lastUsedDescription(for: testModel), "Last used desc should now be populated")
        
        catalog.recordModelLaunch(testModel)
        XCTAssertEqual(catalog.usageCount(for: testModel), 2, "Usage count should increment to 2")
    }
    
    func testModelSortingOptions() {
        let catalog = ModelCatalogService()
        
        let m1 = ModelItem(name: "Beta Model", fileURL: URL(fileURLWithPath: "/tmp/m1.gguf"), format: .gguf, sizeBytes: 1000, engineType: .llamaCpp)
        let m2 = ModelItem(name: "Alpha Model", fileURL: URL(fileURLWithPath: "/tmp/m2.gguf"), format: .gguf, sizeBytes: 5000, engineType: .llamaCpp)
        let m3 = ModelItem(name: "Gamma Model", fileURL: URL(fileURLWithPath: "/tmp/m3.gguf"), format: .gguf, sizeBytes: 3000, engineType: .llamaCpp)
        
        catalog.models = [m1, m2, m3]
        
        // 1. Sort by Name
        catalog.selectedSortOption = .name
        let nameSorted = catalog.filteredModels
        XCTAssertEqual(nameSorted[0].name, "Alpha Model")
        XCTAssertEqual(nameSorted[1].name, "Beta Model")
        XCTAssertEqual(nameSorted[2].name, "Gamma Model")
        
        // 2. Sort by Size (Largest first)
        catalog.selectedSortOption = .size
        let sizeSorted = catalog.filteredModels
        XCTAssertEqual(sizeSorted[0].name, "Alpha Model") // 5000
        XCTAssertEqual(sizeSorted[1].name, "Gamma Model") // 3000
        XCTAssertEqual(sizeSorted[2].name, "Beta Model")  // 1000
        
        // 3. Sort by Most Frequent
        var counts = UserDefaults.standard.dictionary(forKey: "LocalMgrModelUsageCounts") as? [String: Int] ?? [:]
        counts[m1.fileURL.path] = 10
        counts[m2.fileURL.path] = 2
        counts[m3.fileURL.path] = 5
        UserDefaults.standard.set(counts, forKey: "LocalMgrModelUsageCounts")
        
        catalog.selectedSortOption = .mostFrequent
        let freqSorted = catalog.filteredModels
        XCTAssertEqual(freqSorted[0].name, "Beta Model")  // 10
        XCTAssertEqual(freqSorted[1].name, "Gamma Model") // 5
        XCTAssertEqual(freqSorted[2].name, "Alpha Model") // 2
    }

    /// Verifies that `ModelCatalogService.scanFolders` traverses symlinked MLX
    /// directories, resolves symlinked HF snapshot `.safetensors` blobs for
    /// folder size, parses nested `text_config` / `quantization` from
    /// `config.json`, classifies `gemma4` as `.verified`, and computes
    /// `engineModelIdentifier` (`localmgr-n3n`, `localmgr-glp`, `localmgr-jug`).
    func testScanFoldersFollowsSymlinksAndParsesGemma4MLXConfig() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("LocalMgrCatalogTest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempRoot) }

        let hfBlobs = tempRoot.appendingPathComponent("hf-cache/models--mlx-community--gemma-4-e2b-it-4bit/blobs")
        let hfSnap = tempRoot.appendingPathComponent("hf-cache/models--mlx-community--gemma-4-e2b-it-4bit/snapshots/238767527555cb75a05732a84dff5d6ba0dd6809")
        let vaultDir = tempRoot.appendingPathComponent("gemma-vault")
        try fm.createDirectory(at: hfBlobs, withIntermediateDirectories: true)
        try fm.createDirectory(at: hfSnap, withIntermediateDirectories: true)
        try fm.createDirectory(at: vaultDir, withIntermediateDirectories: true)

        // Create a real config blob and a real weight blob, then symlink them inside snapshots/
        let configJSON = """
        {
          "model_type": "gemma4",
          "text_config": {
            "model_type": "gemma4_text",
            "max_position_embeddings": 131072,
            "num_hidden_layers": 26,
            "num_key_value_heads": 4
          },
          "quantization": {
            "bits": 4,
            "group_size": 64
          }
        }
        """.data(using: .utf8)!
        let configBlob = hfBlobs.appendingPathComponent("blob-config")
        let weightBlob = hfBlobs.appendingPathComponent("blob-weights")
        let weightBytes = Data(repeating: 0xAA, count: 65_536)
        try configJSON.write(to: configBlob)
        try weightBytes.write(to: weightBlob)

        try fm.createSymbolicLink(at: hfSnap.appendingPathComponent("config.json"), withDestinationURL: configBlob)
        try fm.createSymbolicLink(at: hfSnap.appendingPathComponent("model.safetensors"), withDestinationURL: weightBlob)

        // Create a directory symlink inside vaultDir -> hfSnap (mirrors ../gemma/mlx-gemma-4-e2b)
        let symlinkedModelDir = vaultDir.appendingPathComponent("mlx-gemma-4-e2b")
        try fm.createSymbolicLink(at: symlinkedModelDir, withDestinationURL: hfSnap)

        // Also place a .litertlm file in vaultDir to verify .litertlm discovery
        let litertFile = vaultDir.appendingPathComponent("gemma3-1b.litertlm")
        try Data(repeating: 0xBB, count: 4096).write(to: litertFile)

        let scanned = ModelCatalogService.scanFolders([vaultDir])
        XCTAssertEqual(scanned.count, 2)

        guard let mlxModel = scanned.first(where: { $0.format == .mlx }) else {
            XCTFail("Expected symlinked MLX model to be discovered")
            return
        }
        XCTAssertEqual(mlxModel.name, "mlx-gemma-4-e2b")
        XCTAssertEqual(mlxModel.engineModelIdentifier, symlinkedModelDir.path)
        XCTAssertEqual(mlxModel.compatibilityTier, .verified)
        XCTAssertEqual(mlxModel.quantization, "MLX-4bit")
        XCTAssertEqual(mlxModel.contextLength, 131072)
        XCTAssertEqual(mlxModel.layerCount, 26)
        XCTAssertEqual(mlxModel.headCountKV, 4)
        XCTAssertEqual(mlxModel.sizeBytes, Int64(configJSON.count + weightBytes.count))

        guard let litertModel = scanned.first(where: { $0.format == .liteRT }) else {
            XCTFail("Expected .litertlm file to be discovered as LiteRT")
            return
        }
        XCTAssertEqual(litertModel.name, "gemma3-1b")
        XCTAssertEqual(litertModel.engineModelIdentifier, "gemma3-1b")
        XCTAssertEqual(litertModel.sizeBytes, 4096)
    }

    func testScanRealGemmaDirectoryWhenPresent() throws {
        let gemmaDir = URL(fileURLWithPath: "/Users/ghchinoy/projects/gemma")
        guard FileManager.default.fileExists(atPath: gemmaDir.path) else {
            throw XCTSkip("Skipping because /Users/ghchinoy/projects/gemma is not present")
        }
        let scanned = ModelCatalogService.scanFolders([gemmaDir])
        XCTAssertGreaterThanOrEqual(scanned.count, 4, "Expected all 4 Gemma 4 models (2 GGUF + 2 MLX) in ../gemma")
        for model in scanned {
            XCTAssertEqual(model.compatibilityTier, .verified, "Model \(model.name) should be classified as .verified")
            XCTAssertGreaterThan(model.sizeBytes, 1_000_000_000, "Model \(model.name) should report resolved multi-GB size")
        }
    }
}
