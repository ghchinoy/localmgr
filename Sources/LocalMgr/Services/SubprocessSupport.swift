import Foundation
import Darwin

/// Outcome of attempting to wait for and terminate a subprocess.
enum ExitOutcome: Equatable, CustomStringConvertible {
    case exited(Int32)     // Process exited cleanly within the timeout
    case killed(Int32?)    // Process had to be SIGKILLed; may include final termination code
    case unknown           // Process was already dead or gone before we started
    
    var description: String {
        switch self {
        case .exited(let code):
            return "Exited with code \(code)"
        case .killed(let code):
            return "Force killed" + (code != nil ? " (termination status: \(code!))" : "")
        case .unknown:
            return "Already dead or gone"
        }
    }
}

/// A fixed-capacity ring buffer of log lines, preventing unbounded memory growth
/// while retaining the last N lines for diagnostic snapshots or error reporting.
struct TailBuffer: Sendable {
    private var lines: [String] = []
    let maxLines: Int
    
    init(maxLines: Int = 2000) {
        self.maxLines = maxLines
    }
    
    mutating func append(_ text: String) {
        let newLines = text.components(separatedBy: .newlines)
        for line in newLines {
            // Avoid adding blank lines at the end of split if they represent trailing newlines
            if line.isEmpty && line == newLines.last { continue }
            lines.append(line)
        }
        
        if lines.count > maxLines {
            let overflow = lines.count - maxLines
            lines.removeFirst(overflow)
        }
    }
    
    mutating func clear() {
        lines.removeAll()
    }
    
    var tail: String {
        lines.joined(separator: "\n")
    }
    
    var lineCount: Int {
        lines.count
    }
}

/// Encapsulates continuous asynchronous background pipe reading for a Process.
/// Solves the standard deadlock risk of unbounded stderr/stdout blocking.
@MainActor
final class SubprocessPipeDrain: @unchecked Sendable {
    private var buffer: TailBuffer
    private let onNewText: @Sendable (String) -> Void
    private let outputPipe = Pipe()
    
    init(maxLines: Int = 2000, onNewText: @Sendable @escaping (String) -> Void) {
        self.buffer = TailBuffer(maxLines: maxLines)
        self.onNewText = onNewText
    }
    
    /// Attaches the Pipe to the given Process stdout and stderr and begins reading.
    nonisolated func attach(to process: Process) {
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                Task { @MainActor [weak self] in
                    self?.buffer.append(text)
                    self?.onNewText(text)
                }
            }
        }
    }
    
    /// Stops the readability handler and detaches from the Pipe.
    nonisolated func stop() {
        outputPipe.fileHandleForReading.readabilityHandler = nil
    }
    
    /// Takes a current snapshot of the tail buffer logs.
    var snapshot: String {
        buffer.tail
    }
}

/// Hardened subprocess watcher that executes bounded waits, walks the child-process tree (pgrep),
/// and escalates from SIGTERM to SIGKILL to guarantee termination.
struct SubprocessWatchdog {
    /// Walk the child process tree using `pgrep -P <parentPID>` to locate spawned subprocesses.
    static func getChildPIDs(parentPID: Int32) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", "\(parentPID)"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output.components(separatedBy: .newlines)
                    .compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .compactMap { Int32($0) }
            }
        } catch {
            // Silently fall back to empty child tree if pgrep fails
        }
        return []
    }
    
    /// Bounded termination watch loop. Sends SIGTERM, walks child tree, escalates to SIGKILL if hung.
    static func waitForExit(process: Process, timeout: TimeInterval) async -> ExitOutcome {
        guard process.isRunning else {
            return .unknown
        }
        
        let pid = process.processIdentifier
        let children = getChildPIDs(parentPID: pid)
        
        // 1. Signal SIGTERM to the children and the parent process
        for childPID in children {
            kill(childPID, SIGTERM)
        }
        kill(pid, SIGTERM)
        
        let startTime = Date()
        let pollInterval: TimeInterval = 0.05
        
        // 2. Poll process.isRunning to see if it exits cleanly within the timeout
        while Date().timeIntervalSince(startTime) < timeout {
            if !process.isRunning {
                return .exited(process.terminationStatus)
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        
        // 3. Escalation: Send SIGKILL to remaining processes in the tree
        if process.isRunning {
            for childPID in children {
                kill(childPID, SIGKILL)
            }
            kill(pid, SIGKILL)
            
            // Brief final check to observe status
            try? await Task.sleep(nanoseconds: 50_000_000)
            return .killed(process.isRunning ? nil : process.terminationStatus)
        }
        
        return .exited(process.terminationStatus)
    }
}
