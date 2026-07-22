import Foundation
import Darwin

/// Layer-1 crash-safety watchdog (localmgr-853.6): detects and cleans up engine
/// subprocesses orphaned by a force-quit (`kill -9`) or crash of LocalMgr itself.
///
/// `AppDelegate.applicationWillTerminate` only fires on a *clean* quit; if
/// LocalMgr itself is force-quit or crashes while an engine subprocess (e.g.
/// llama-server) is running, that subprocess is orphaned -- it keeps holding a
/// port and VRAM/RAM with no supervising LocalMgr process and no UI record.
///
/// Modeled on MTPLX's Layer 1 thermal-crash-safety pattern (`thermal.py`),
/// generalized here to engine subprocess cleanup instead of fan state: on
/// spawning an engine, LocalMgr records a marker file naming its own PID and
/// the spawned engine's PID. On the *next* launch, before spawning anything
/// new, it checks whether the recorded LocalMgr PID from a prior marker is
/// still alive. If not, the prior session clearly did not exit cleanly, so the
/// recorded engine PID is orphaned and is terminated.
///
/// Deliberately terminates rather than adopts: adoption (`localmgr-jhj.8`) is
/// model-specific and requires the model catalog to already be loaded, which is
/// not guaranteed at this very early startup check. A future enhancement could
/// route a detected orphan through the catalog once loaded and offer adoption
/// instead, per the epic description.
enum CrashSafetyWatchdog {

    struct Marker: Codable, Equatable {
        let localMgrPID: Int32
        let enginePID: Int32
        let engineName: String
        let modelName: String
        let modelPath: String
        let port: Int
        let startedAt: Date
    }

    /// Outcome of a startup orphan check, surfaced so the caller can log it.
    enum OrphanCheckResult: Equatable {
        /// No marker existed, or the recorded LocalMgr PID is still alive
        /// (not a crash -- left untouched defensively).
        case noOrphan
        /// A marker was found whose LocalMgr PID is no longer alive; the
        /// recorded engine PID was still alive too and was force-terminated.
        case terminatedOrphan(Marker)
        /// A marker was found and its LocalMgr PID is dead, but its engine PID
        /// was already gone too -- nothing left to clean up, just cleared.
        case staleMarkerOnly(Marker)
    }

    // MARK: - Storage

    static var markerDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("LocalMgr/RunningEngines", isDirectory: true)
    }

    /// Single marker file: `BackendRunnerManager` supervises exactly one
    /// spawned engine process at a time (`startModel` always calls
    /// `stopCurrent()` first), so one marker is sufficient -- it always
    /// describes "the currently LocalMgr-owned engine process", overwritten on
    /// each new spawn and removed on clean stop/exit.
    private static var markerFileURL: URL {
        markerDirectory.appendingPathComponent("active-runner.json")
    }

    /// Persists a marker for a just-spawned, LocalMgr-owned engine process.
    /// Best-effort -- a write failure only means crash-safety cleanup is
    /// skipped next launch, never a functional failure of the current launch.
    @discardableResult
    static func writeMarker(_ marker: Marker) -> Bool {
        do {
            try FileManager.default.createDirectory(at: markerDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(marker)
            try data.write(to: markerFileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Removes the marker after a clean stop/exit -- the engine is no longer
    /// LocalMgr's responsibility, so there is nothing to detect as orphaned on
    /// the next launch. Safe to call even if no marker exists.
    @discardableResult
    static func clearMarker() -> Bool {
        (try? FileManager.default.removeItem(at: markerFileURL)) != nil
    }

    /// Reads the persisted marker, if any, without side effects.
    static func readMarker() -> Marker? {
        guard let data = try? Data(contentsOf: markerFileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Marker.self, from: data)
    }

    // MARK: - Liveness probe

    /// Whether a process with the given PID currently exists. Uses
    /// `kill(pid, 0)` (the standard POSIX liveness probe -- sends no signal,
    /// only checks whether the target is permitted/exists) rather than
    /// `waitpid`, which only works for a direct child; neither a prior
    /// LocalMgr instance nor its now-orphaned engine is a child of the current
    /// process.
    static func isProcessAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    // MARK: - Decision (pure, unit-testable)

    enum Decision: Equatable {
        case doNothing
        case terminate(Marker)
    }

    /// Pure decision logic given an already-loaded marker (or nil) and an
    /// injectable liveness probe -- factored out so it is unit-testable
    /// without real PIDs or file I/O. Does not perform termination; returns
    /// what the caller should do.
    static func decide(marker: Marker?, isAlive: (Int32) -> Bool) -> Decision {
        guard let marker else { return .doNothing }
        // The recorded LocalMgr PID is still alive -- either this genuinely
        // is a still-running session (shouldn't happen: this check runs once
        // at startup, before this session's own marker is written) or,
        // defensively, a PID coincidence. Never touch a process while its
        // recorded owner might still be alive.
        if isAlive(marker.localMgrPID) {
            return .doNothing
        }
        return .terminate(marker)
    }

    // MARK: - Orchestration

    /// Runs the full startup orphan check: read the marker, decide, and (if
    /// termination is warranted) actually kill the orphaned engine process via
    /// bounded SIGTERM-then-SIGKILL escalation, then clear the marker. Call
    /// once at app startup, before any new engine is spawned.
    @discardableResult
    static func checkForOrphansAtLaunch() async -> OrphanCheckResult {
        let marker = readMarker()
        switch decide(marker: marker, isAlive: isProcessAlive) {
        case .doNothing:
            return .noOrphan
        case .terminate(let m):
            defer { clearMarker() }
            guard isProcessAlive(pid: m.enginePID) else {
                // The engine died too (e.g. alongside LocalMgr) -- nothing
                // left to terminate, just clear the stale marker.
                return .staleMarkerOnly(m)
            }
            kill(m.enginePID, SIGTERM)
            // ~1s bounded wait, matching SubprocessWatchdog's escalation cadence.
            for _ in 0..<20 {
                if !isProcessAlive(pid: m.enginePID) { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if isProcessAlive(pid: m.enginePID) {
                kill(m.enginePID, SIGKILL)
            }
            return .terminatedOrphan(m)
        }
    }

    /// Synchronously terminates the engine recorded in the current marker (if
    /// any) and clears the marker. Used by the Layer-2 signal handlers
    /// (`installSignalHandlers`), where the process is about to die and there is
    /// no time for an async escalation loop: we send SIGTERM, spin a brief
    /// bounded busy-wait, then SIGKILL if still alive. Safe to call when no
    /// marker exists (no-op). Returns the PID that was signaled, if any.
    @discardableResult
    static func reapCurrentEngineSynchronously() -> Int32? {
        guard let marker = readMarker() else { return nil }
        defer { clearMarker() }
        guard isProcessAlive(pid: marker.enginePID) else { return nil }
        kill(marker.enginePID, SIGTERM)
        // Brief bounded wait (~500ms) using usleep -- we are on a shutdown path
        // and cannot rely on the run loop / Swift concurrency still servicing us.
        for _ in 0..<50 {
            if !isProcessAlive(pid: marker.enginePID) { break }
            usleep(10_000)
        }
        if isProcessAlive(pid: marker.enginePID) {
            kill(marker.enginePID, SIGKILL)
        }
        return marker.enginePID
    }

    // MARK: - Layer 2: signal handlers

    /// Retained signal sources; kept alive for the process lifetime once
    /// installed. Never mutated after `installSignalHandlers` returns.
    private nonisolated(unsafe) static var signalSources: [DispatchSourceSignal] = []

    /// Installs Layer-2 crash-safety handlers for SIGINT/SIGTERM/SIGHUP.
    ///
    /// These cover terminations that are NOT clean quits but ARE catchable:
    /// `kill <pid>` (SIGTERM), Ctrl-C in a dev terminal (SIGINT), and closing a
    /// controlling terminal LocalMgr was launched from (SIGHUP). On receipt we
    /// synchronously terminate the LocalMgr-owned engine and clear the marker,
    /// then re-raise the signal with the default disposition so the process
    /// still terminates exactly as it normally would.
    ///
    /// This complements (does not replace) `applicationWillTerminate` (clean
    /// quit, Layer 0) and the launch-time orphan check + detached sidecar
    /// (Layers 1/3). `SIGKILL` cannot be caught by design -- that gap is what
    /// the Layer-3 sidecar (`localmgr-853.8`) exists to close.
    ///
    /// We use `DispatchSourceSignal` rather than a raw C `signal()` handler so
    /// the cleanup work runs in a normal Swift context (async-signal-safety is
    /// not a concern), and we must call `signal(sig, SIG_IGN)` first so the
    /// default disposition does not kill us before the source fires.
    static func installSignalHandlers(onCleanup: (@Sendable (Int32, Int32?) -> Void)? = nil) {
        let signalsToHandle: [Int32] = [SIGINT, SIGTERM, SIGHUP]
        for sig in signalsToHandle {
            // Ignore the default disposition so the dispatch source can handle it.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                let reapedPID = reapCurrentEngineSynchronously()
                onCleanup?(sig, reapedPID)
                // Restore default disposition and re-raise so the process
                // terminates normally with the expected signal semantics.
                signal(sig, SIG_DFL)
                raise(sig)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
