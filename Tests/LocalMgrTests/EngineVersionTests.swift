import XCTest
@testable import LocalMgr

final class EngineVersionTests: XCTestCase {
    func testSemanticVersionComparator() {
        // Test standard semver comparison
        XCTAssertTrue(SemanticVersionComparator.isOutdated(installed: "0.31.3", latest: "0.32.1"))
        XCTAssertTrue(SemanticVersionComparator.isOutdated(installed: "0.31.3", latest: "1.0.0"))
        XCTAssertFalse(SemanticVersionComparator.isOutdated(installed: "0.31.3", latest: "0.31.3"))
        XCTAssertFalse(SemanticVersionComparator.isOutdated(installed: "0.31.3", latest: "0.30.9"))
        
        // Test with pre-release or build suffixes
        XCTAssertTrue(SemanticVersionComparator.isOutdated(installed: "0.31.3-rc1", latest: "0.31.4"))
        
        // Test plain integer comparisons (llama.cpp build numbers)
        XCTAssertTrue(SemanticVersionComparator.isOutdated(installed: "9840", latest: "9850"))
        XCTAssertTrue(SemanticVersionComparator.isOutdated(installed: "b9840", latest: "b9850"))
        XCTAssertFalse(SemanticVersionComparator.isOutdated(installed: "9850", latest: "9840"))
        XCTAssertFalse(SemanticVersionComparator.isOutdated(installed: "9840", latest: "9840"))
        
        // Test mixed and messy input formats
        XCTAssertTrue(SemanticVersionComparator.isOutdated(installed: "v0.14.0", latest: "v0.15.2"))
        XCTAssertFalse(SemanticVersionComparator.isOutdated(installed: "v0.15.2", latest: "0.14.0"))
    }
}
