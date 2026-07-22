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

    // MARK: - Synchronous reap (Layer-2 signal path)

    func testReapWithNoMarkerReturnsNil() {
        CrashSafetyWatchdog.clearMarker()
        XCTAssertNil(CrashSafetyWatchdog.reapCurrentEngineSynchronously())
    }

    /// A marker whose engine PID is already dead should just clear the marker
    /// and report nothing reaped -- no signal sent to a non-existent PID.
    func testReapWithDeadEnginePIDClearsMarkerReturnsNil() {
        // Use a PID that is essentially guaranteed not to exist.
        let marker = makeMarker(localMgrPID: ProcessInfo.processInfo.processIdentifier, enginePID: 2_000_000_000)
        XCTAssertTrue(CrashSafetyWatchdog.writeMarker(marker))
        let reaped = CrashSafetyWatchdog.reapCurrentEngineSynchronously()
        XCTAssertNil(reaped)
        // Marker must be cleared regardless.
        XCTAssertNil(CrashSafetyWatchdog.readMarker())
    }

    /// End-to-end synchronous reap against a REAL child process: spawn a
    /// long-sleeping /bin/sleep, record it as the engine, and confirm the
    /// synchronous reaper terminates it and clears the marker.
    func testReapTerminatesRealProcess() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["600"]
        try proc.run()
        let enginePID = proc.processIdentifier
        XCTAssertTrue(CrashSafetyWatchdog.isProcessAlive(pid: enginePID))

        let marker = makeMarker(localMgrPID: ProcessInfo.processInfo.processIdentifier, enginePID: enginePID)
        XCTAssertTrue(CrashSafetyWatchdog.writeMarker(marker))

        let reaped = CrashSafetyWatchdog.reapCurrentEngineSynchronously()
        XCTAssertEqual(reaped, enginePID)

        // Give the OS a beat to fully reap, then confirm it is gone.
        var stillAlive = true
        for _ in 0..<50 {
            if !CrashSafetyWatchdog.isProcessAlive(pid: enginePID) { stillAlive = false; break }
            usleep(10_000)
        }
        XCTAssertFalse(stillAlive, "sleep process should have been terminated")
        XCTAssertNil(CrashSafetyWatchdog.readMarker())
        proc.waitUntilExit()
    }
}
