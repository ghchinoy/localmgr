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
}
