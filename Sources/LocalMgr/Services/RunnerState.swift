import Foundation

struct RunnerState: Equatable {
    enum Status: Equatable {
        case stopped
        case starting
        case warming
        case running
        case degraded(String)
        case stopping
        case crashed(Int32?)

        var legacyStatus: RunnerStatus {
            switch self {
            case .stopped:
                return .stopped
            case .starting, .warming, .stopping:
                return .starting
            case .running, .degraded:
                return .running
            case .crashed:
                return .error
            }
        }
    }

    var status: Status
    var activeModel: ModelItem?
    var lastRunModelID: UUID?
    var logOutput: String
    var totalRequestsServed: Int
    var totalTokensProcessed: Int
    var lastTTFTMilliseconds: Double
    var lastTokensPerSecond: Double
    var sessionStartTime: Date?

    init(
        status: Status = .stopped,
        activeModel: ModelItem? = nil,
        lastRunModelID: UUID? = nil,
        logOutput: String = "",
        totalRequestsServed: Int = 0,
        totalTokensProcessed: Int = 0,
        lastTTFTMilliseconds: Double = 0.0,
        lastTokensPerSecond: Double = 0.0,
        sessionStartTime: Date? = nil
    ) {
        self.status = status
        self.activeModel = activeModel
        self.lastRunModelID = lastRunModelID
        self.logOutput = logOutput
        self.totalRequestsServed = totalRequestsServed
        self.totalTokensProcessed = totalTokensProcessed
        self.lastTTFTMilliseconds = lastTTFTMilliseconds
        self.lastTokensPerSecond = lastTokensPerSecond
        self.sessionStartTime = sessionStartTime
    }

    /// Pure transition to start a model
    func start(model: ModelItem) -> RunnerState {
        var newState = self
        newState.status = .starting
        newState.activeModel = model
        newState.lastRunModelID = model.id
        newState.sessionStartTime = Date()
        newState.totalRequestsServed = 0
        newState.totalTokensProcessed = 0
        newState.lastTTFTMilliseconds = 0.0
        newState.lastTokensPerSecond = 0.0
        newState.logOutput = "\n--- Starting \(model.name) via \(model.engineType.rawValue) ---\n"
        return newState
    }

    /// Pure transition to mark as starting
    func markStarting() -> RunnerState {
        var newState = self
        newState.status = .starting
        return newState
    }

    /// Pure transition to mark as warming
    func markWarming() -> RunnerState {
        var newState = self
        newState.status = .warming
        return newState
    }

    /// Pure transition to mark as running
    func markRunning() -> RunnerState {
        var newState = self
        newState.status = .running
        return newState
    }

    /// Pure transition to mark as degraded
    func markDegraded(reason: String) -> RunnerState {
        var newState = self
        newState.status = .degraded(reason)
        return newState
    }

    /// Pure transition to mark as stopping
    func markStopping() -> RunnerState {
        var newState = self
        newState.status = .stopping
        return newState
    }

    /// Pure transition to handle process termination
    func terminate(exitCode: Int32?) -> RunnerState {
        var newState = self
        if let exitCode = exitCode, exitCode != 0 {
            newState.status = .crashed(exitCode)
            newState.logOutput.append("\n[Runner process terminated unexpectedly with exit code \(exitCode)]\n")
        } else {
            newState.status = .stopped
            newState.logOutput.append("\n[Runner process exited cleanly]\n")
        }
        newState.activeModel = nil
        newState.sessionStartTime = nil
        return newState
    }

    /// Pure transition to stop the runner cleanly
    func stop() -> RunnerState {
        var newState = self
        newState.status = .stopped
        newState.activeModel = nil
        newState.sessionStartTime = nil
        return newState
    }

    /// Pure transition to handle an immediate startup/configuration error
    func markError(reason: String) -> RunnerState {
        var newState = self
        newState.status = .crashed(nil) // Maps to legacy .error
        newState.logOutput.append("\nERROR: \(reason)\n")
        return newState
    }

    /// Pure transition to append log output
    func appendLog(_ text: String) -> RunnerState {
        var newState = self
        newState.logOutput.append(text)
        return newState
    }

    /// Pure transition to clear logs
    func clearLogs() -> RunnerState {
        var newState = self
        newState.logOutput = ""
        return newState
    }

    /// Pure transition to record telemetry metrics
    func recordTelemetry(ttftMs: Double, durationMs: Double, completionTokens: Int) -> RunnerState {
        var newState = self
        newState.totalRequestsServed += 1
        newState.totalTokensProcessed += completionTokens
        if ttftMs > 0 { newState.lastTTFTMilliseconds = ttftMs }
        if durationMs > 0 && completionTokens > 0 {
            newState.lastTokensPerSecond = Double(completionTokens) / (durationMs / 1000.0)
        }
        return newState
    }
}
