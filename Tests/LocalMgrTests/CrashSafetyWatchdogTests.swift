import XCTest
@testable import LocalMgr

final class CrashSafetyWatchdogTests: XCTestCase {

    private func makeMarker(localMgrPID: Int32 = 999, enginePID: Int32 = 1000) -> CrashSafetyWatchdog.Marker {
        CrashSafetyWatchdog.Marker(
            localMgrPID: localMgrPID,
            enginePID: enginePID,
            engineName: "llama-server",
            modelName: "Test Model",
            modelPath: "/tmp/test.gguf",
            port: 8080,
            startedAt: Date()
        )
    }

    // MARK: - Decision logic (pure)

    func testNoMarkerDoesNothing() {
        let decision = CrashSafetyWatchdog.decide(marker: nil, isAlive: { _ in true })
        XCTAssertEqual(decision, .doNothing)
    }

    /// Recorded LocalMgr PID still alive -> never touch the engine.
    func testLiveOwnerDoesNothing() {
        let marker = makeMarker(localMgrPID: 999)
        let decision = CrashSafetyWatchdog.decide(marker: marker) { pid in pid == 999 }
        XCTAssertEqual(decision, .doNothing)
    }

    /// Recorded LocalMgr PID dead -> the engine is orphaned, terminate it.
    func testDeadOwnerTriggersTerminate() {
        let marker = makeMarker(localMgrPID: 999, enginePID: 1000)
        // Owner (999) dead, engine (1000) alive.
        let decision = CrashSafetyWatchdog.decide(marker: marker) { pid in pid == 1000 }
        XCTAssertEqual(decision, .terminate(marker))
    }

    func testDeadOwnerAndDeadEngineStillDecidesTerminate() {
        // decide() only gates on owner liveness; the orchestration layer then
        // handles the already-dead-engine case as staleMarkerOnly.
        let marker = makeMarker(localMgrPID: 999, enginePID: 1000)
        let decision = CrashSafetyWatchdog.decide(marker: marker) { _ in false }
        XCTAssertEqual(decision, .terminate(marker))
    }

    // MARK: - Liveness probe

    func testCurrentProcessIsAlive() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(CrashSafetyWatchdog.isProcessAlive(pid: selfPID))
    }

    func testInvalidPIDsNotAlive() {
        XCTAssertFalse(CrashSafetyWatchdog.isProcessAlive(pid: 0))
        XCTAssertFalse(CrashSafetyWatchdog.isProcessAlive(pid: -1))
        // Very high PID extremely unlikely to exist.
        XCTAssertFalse(CrashSafetyWatchdog.isProcessAlive(pid: 2_000_000_000))
    }

    // MARK: - Marker persistence round-trip

    func testMarkerRoundTrip() {
        // Ensure a clean slate, then round-trip.
        CrashSafetyWatchdog.clearMarker()
        defer { CrashSafetyWatchdog.clearMarker() }

        let marker = makeMarker(localMgrPID: 12345, enginePID: 67890)
        XCTAssertTrue(CrashSafetyWatchdog.writeMarker(marker))

        let loaded = CrashSafetyWatchdog.readMarker()
        XCTAssertEqual(loaded?.localMgrPID, 12345)
        XCTAssertEqual(loaded?.enginePID, 67890)
        XCTAssertEqual(loaded?.engineName, "llama-server")
        XCTAssertEqual(loaded?.modelName, "Test Model")
        XCTAssertEqual(loaded?.port, 8080)
    }

    func testClearMarkerRemovesIt() {
        let marker = makeMarker()
        XCTAssertTrue(CrashSafetyWatchdog.writeMarker(marker))
        XCTAssertNotNil(CrashSafetyWatchdog.readMarker())
        XCTAssertTrue(CrashSafetyWatchdog.clearMarker())
        XCTAssertNil(CrashSafetyWatchdog.readMarker())
    }

    func testReadMarkerNilWhenAbsent() {
        CrashSafetyWatchdog.clearMarker()
        XCTAssertNil(CrashSafetyWatchdog.readMarker())
    }
}
