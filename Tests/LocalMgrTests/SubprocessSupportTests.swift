import XCTest
@testable import LocalMgr

final class SubprocessSupportTests: XCTestCase {
    
    func testTailBufferAppendUnderCapacity() {
        var buffer = TailBuffer(maxLines: 5)
        buffer.append("line1")
        buffer.append("line2\nline3")
        
        XCTAssertEqual(buffer.lineCount, 3)
        XCTAssertEqual(buffer.tail, "line1\nline2\nline3")
    }
    
    func testTailBufferAppendOverCapacity() {
        var buffer = TailBuffer(maxLines: 3)
        buffer.append("line1")
        buffer.append("line2")
        buffer.append("line3")
        buffer.append("line4")
        
        XCTAssertEqual(buffer.lineCount, 3)
        XCTAssertEqual(buffer.tail, "line2\nline3\nline4")
    }
    
    func testTailBufferMultiLineSplit() {
        var buffer = TailBuffer(maxLines: 10)
        buffer.append("a\nb\nc\nd\n")
        
        XCTAssertEqual(buffer.lineCount, 4)
        XCTAssertEqual(buffer.tail, "a\nb\nc\nd")
    }
    
    func testTailBufferClear() {
        var buffer = TailBuffer(maxLines: 5)
        buffer.append("hello")
        XCTAssertEqual(buffer.lineCount, 1)
        
        buffer.clear()
        XCTAssertEqual(buffer.lineCount, 0)
        XCTAssertEqual(buffer.tail, "")
    }
    
    func testWatchdogCleanExit() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        
        do {
            try process.run()
            let outcome = await SubprocessWatchdog.waitForExit(process: process, timeout: 2.0)
            XCTAssertEqual(outcome, .exited(0))
        } catch {
            XCTFail("Failed to run true process: \(error)")
        }
    }
    
    func testWatchdogTimeoutEscalation() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "trap '' SIGTERM; sleep 10"]
        
        do {
            try process.run()
            XCTAssertTrue(process.isRunning)
            
            // Bounded wait of 0.2 seconds should force a SIGKILL escalation
            let outcome = await SubprocessWatchdog.waitForExit(process: process, timeout: 0.2)
            
            XCTAssertFalse(process.isRunning, "Process must be terminated after watchdog completes")
            switch outcome {
            case .killed:
                XCTAssertTrue(true, "Successfully escalated to SIGKILL")
            default:
                XCTFail("Expected process to be killed (SIGKILL), but got: \(outcome)")
            }
        } catch {
            XCTFail("Failed to run sleep process: \(error)")
        }
    }
    
    func testWatchdogUnknownProcess() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        
        // Process is not started
        let outcome = await SubprocessWatchdog.waitForExit(process: process, timeout: 2.0)
        XCTAssertEqual(outcome, .unknown)
    }
}
