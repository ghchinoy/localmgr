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

    var shortMemorySummary: String {
        let usedGB = Double(usedRAMBytes) / 1_073_741_824.0
        let totalGB = Double(totalRAMBytes) / 1_073_741_824.0
        return String(format: "%.1f/%.0f GB", usedGB, totalGB)
    }

    init() {
        totalRAMBytes = Int64(ProcessInfo.processInfo.physicalMemory)
        updateTelemetry()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateTelemetry()
            }
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

    func calculateFitScore(for model: ModelItem) -> MemoryFitScore {
        let modelSize = model.sizeBytes
        // Add ~20% overhead for KV cache and runtime activations
        let estimatedRequired = Int64(Double(modelSize) * 1.25)
        
        if estimatedRequired < freeRAMBytes {
            return .excellent
        } else if estimatedRequired < (freeRAMBytes + 2_000_000_000) {
            return .tight
        } else {
            return .thrashing
        }
    }
}
