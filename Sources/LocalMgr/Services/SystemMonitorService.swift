import Foundation
import Combine
import Darwin

enum MemoryFitScore: String {
    case excellent = "Excellent Fit"
    case tight = "Tight / Moderate Pressure"
    case thrashing = "Exceeds Physical RAM (Will Swap)"

    var colorName: String {
        switch self {
        case .excellent: return "green"
        case .tight: return "orange"
        case .thrashing: return "red"
        }
    }
}

@MainActor
class SystemMonitorService: ObservableObject {
    @Published var totalRAMBytes: Int64 = 0
    @Published var usedRAMBytes: Int64 = 0
    @Published var freeRAMBytes: Int64 = 0
    @Published var memoryFitScore: MemoryFitScore = .excellent

    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private weak var runnerManager: BackendRunnerManager?

    /// Edge-triggered hysteresis decision core over
    /// `kern.memorystatus_vm_pressure_level` (see `MemoryPressureGuard.swift`).
    /// Evaluated both on `DispatchSource` pressure-change notifications
    /// (for prompt reaction) and on the existing 2s telemetry timer (so a
    /// continuously-elevated level still gets re-evaluated once its
    /// re-arm cooldown elapses, even without a fresh kernel notification).
    private var pressureGuard = MemoryPressureGuard()

    var shortMemorySummary: String {
        let usedGB = Double(usedRAMBytes) / 1_073_741_824.0
        let totalGB = Double(totalRAMBytes) / 1_073_741_824.0
        return String(format: "%.1f/%.0f GB", usedGB, totalGB)
    }

    init() {
        totalRAMBytes = Int64(ProcessInfo.processInfo.physicalMemory)
        updateTelemetry()
        setupPressureListener()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateTelemetry()
                self?.evaluateMemoryPressure()
            }
        }
    }

    func configure(runner: BackendRunnerManager) {
        self.runnerManager = runner
    }

    private func setupPressureListener() {
        // Listen for both .warning and .critical kernel notifications so we
        // react promptly on either transition; the actual decision (act now
        // vs. defer vs. re-arm cooldown) is delegated to `pressureGuard`,
        // not decided here. The 2s telemetry timer above additionally
        // re-evaluates the guard on a fixed cadence so a level that stays
        // continuously elevated is still re-checked once its cooldown
        // elapses, even if the kernel doesn't emit another edge notification.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.evaluateMemoryPressure()
            }
        }
        source.resume()
        self.pressureSource = source
    }

    /// Polls the current kernel memory-pressure level through
    /// `pressureGuard` and, if it recommends action, asks
    /// `BackendRunnerManager` to soft- or hard-evict the current runner.
    /// `MemoryPressureGuard` itself never touches the runner -- this is the
    /// only place that translates its recommendation into an actual
    /// eviction call, per LocalMgr's zero-dependency architecture (no ML/
    /// external process introspection required, pure Darwin sysctl polling).
    private func evaluateMemoryPressure() {
        guard let runner = runnerManager else { return }
        let action = pressureGuard.evaluate(requestInFlight: runner.recentlyActive)
        switch action {
        case .none:
            break
        case .softEvict:
            runner.stopIfIdle(reason: "macOS reported WARNING memory pressure. Stopping the idle runner to release RAM before pressure escalates to critical.")
        case .hardEvict:
            runner.stopForCriticalPressure(reason: "macOS reported CRITICAL memory pressure (thrashing). Stopping the runner instantly to protect system responsiveness.")
        }
    }

    func updateTelemetry() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        if result == KERN_SUCCESS {
            let pageSize = Int64(getpagesize())
            let active = Int64(stats.active_count) * pageSize
            let wire = Int64(stats.wire_count) * pageSize
            let compressed = Int64(stats.compressor_page_count) * pageSize
            
            self.usedRAMBytes = active + wire + compressed
            self.freeRAMBytes = max(0, totalRAMBytes - usedRAMBytes)
        }
    }

    func calculateFitScore(for model: ModelItem, contextLength: Int = 8192) -> MemoryFitScore {
        let breakdown = model.memoryPressure(forContextLength: contextLength)
        let estimatedRequired = breakdown.totalRequiredBytes
        
        if estimatedRequired < freeRAMBytes {
            return .excellent
        } else if estimatedRequired < (freeRAMBytes + 2_000_000_000) {
            return .tight
        } else {
            return .thrashing
        }
    }
}
