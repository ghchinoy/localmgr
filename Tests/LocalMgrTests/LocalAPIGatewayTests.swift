import XCTest
@testable import LocalMgr

@MainActor
final class LocalAPIGatewayTests: XCTestCase {
    
    func testGatewayWakeFailureMapping() {
        let runner = BackendRunnerManager()
        
        // Setup initial states
        runner.startupPhase = .failed("Could not find binary 'llama-server' in system PATH")
        
        if case .failed(let reason) = runner.startupPhase! {
            XCTAssertEqual(reason, "Could not find binary 'llama-server' in system PATH")
        } else {
            XCTFail("Expected .failed phase")
        }
    }
}
