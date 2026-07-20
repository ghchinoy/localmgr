import XCTest
@testable import LocalMgr

final class RunnerStateTests: XCTestCase {
    
    private func makeDummyModel() -> ModelItem {
        return ModelItem(
            name: "Test Model",
            fileURL: URL(fileURLWithPath: "/tmp/test.gguf"),
            format: .gguf,
            sizeBytes: 123456789,
            engineType: .llamaCpp,
            quantization: nil,
            contextLength: nil,
            layerCount: nil,
            headCountKV: nil,
            chatTemplate: nil,
            compatibilityTier: .verified,
            compatibilityMessage: "No specific compatibility concerns detected.",
            compatibilityRecommendedAction: nil
        )
    }

    func testInitialState() {
        let state = RunnerState()
        XCTAssertEqual(state.status, .stopped)
        XCTAssertNil(state.activeModel)
        XCTAssertNil(state.lastRunModelID)
        XCTAssertEqual(state.logOutput, "")
        XCTAssertEqual(state.totalRequestsServed, 0)
        XCTAssertEqual(state.totalTokensProcessed, 0)
        XCTAssertEqual(state.lastTTFTMilliseconds, 0.0)
        XCTAssertEqual(state.lastTokensPerSecond, 0.0)
        XCTAssertNil(state.sessionStartTime)
    }

    func testStartModel() {
        let state = RunnerState()
        let model = makeDummyModel()
        
        let startedState = state.start(model: model)
        XCTAssertEqual(startedState.status, .starting)
        XCTAssertEqual(startedState.activeModel, model)
        XCTAssertEqual(startedState.lastRunModelID, model.id)
        XCTAssertNotNil(startedState.sessionStartTime)
        XCTAssertTrue(startedState.logOutput.contains("Starting Test Model via llama.cpp"))
    }

    func testMarkRunning() {
        let state = RunnerState().start(model: makeDummyModel())
        XCTAssertEqual(state.status, .starting)
        
        let runningState = state.markRunning()
        XCTAssertEqual(runningState.status, .running)
    }

    func testMarkWarming() {
        let state = RunnerState().start(model: makeDummyModel())
        XCTAssertEqual(state.status, .starting)
        
        let warmingState = state.markWarming()
        XCTAssertEqual(warmingState.status, .warming)
    }

    func testMarkDegraded() {
        let state = RunnerState().start(model: makeDummyModel()).markRunning()
        XCTAssertEqual(state.status, .running)
        
        let degradedState = state.markDegraded(reason: "Low memory warning")
        XCTAssertEqual(degradedState.status, .degraded("Low memory warning"))
    }

    func testCleanExit() {
        let state = RunnerState().start(model: makeDummyModel()).markRunning()
        
        let stoppedState = state.terminate(exitCode: 0)
        XCTAssertEqual(stoppedState.status, .stopped)
        XCTAssertNil(stoppedState.activeModel)
        XCTAssertNil(stoppedState.sessionStartTime)
        XCTAssertTrue(stoppedState.logOutput.contains("process exited cleanly"))
    }

    func testCrashExit() {
        let state = RunnerState().start(model: makeDummyModel()).markWarming()
        
        let crashedState = state.terminate(exitCode: 1)
        XCTAssertEqual(crashedState.status, .crashed(1))
        XCTAssertNil(crashedState.activeModel)
        XCTAssertNil(crashedState.sessionStartTime)
        XCTAssertTrue(crashedState.logOutput.contains("process terminated unexpectedly with exit code 1"))
    }

    func testStopManually() {
        let state = RunnerState().start(model: makeDummyModel()).markRunning()
        
        let stoppedState = state.stop()
        XCTAssertEqual(stoppedState.status, .stopped)
        XCTAssertNil(stoppedState.activeModel)
        XCTAssertNil(stoppedState.sessionStartTime)
    }

    func testMarkError() {
        let state = RunnerState()
        
        let errorState = state.markError(reason: "Binary not found")
        XCTAssertEqual(errorState.status, .crashed(nil))
        XCTAssertTrue(errorState.logOutput.contains("ERROR: Binary not found"))
    }

    func testRecordTelemetry() {
        var state = RunnerState().start(model: makeDummyModel()).markRunning()
        
        state = state.recordTelemetry(ttftMs: 120.0, durationMs: 1000.0, completionTokens: 50)
        XCTAssertEqual(state.totalRequestsServed, 1)
        XCTAssertEqual(state.totalTokensProcessed, 50)
        XCTAssertEqual(state.lastTTFTMilliseconds, 120.0)
        XCTAssertEqual(state.lastTokensPerSecond, 50.0)
        
        // Record another request, verifying aggregation
        state = state.recordTelemetry(ttftMs: 90.0, durationMs: 500.0, completionTokens: 40)
        XCTAssertEqual(state.totalRequestsServed, 2)
        XCTAssertEqual(state.totalTokensProcessed, 90)
        XCTAssertEqual(state.lastTTFTMilliseconds, 90.0)
        XCTAssertEqual(state.lastTokensPerSecond, 80.0) // 40 tokens / 0.5s = 80 tokens/s
    }

    func testAppendAndClearLogs() {
        var state = RunnerState()
        state = state.appendLog("Line 1\n")
        state = state.appendLog("Line 2\n")
        XCTAssertEqual(state.logOutput, "Line 1\nLine 2\n")
        
        state = state.clearLogs()
        XCTAssertEqual(state.logOutput, "")
    }

    func testLegacyStatusMapping() {
        XCTAssertEqual(RunnerState.Status.stopped.legacyStatus, .stopped)
        XCTAssertEqual(RunnerState.Status.starting.legacyStatus, .starting)
        XCTAssertEqual(RunnerState.Status.warming.legacyStatus, .starting)
        XCTAssertEqual(RunnerState.Status.stopping.legacyStatus, .starting)
        XCTAssertEqual(RunnerState.Status.running.legacyStatus, .running)
        XCTAssertEqual(RunnerState.Status.degraded("warning").legacyStatus, .running)
        XCTAssertEqual(RunnerState.Status.crashed(1).legacyStatus, .error)
    }
}
