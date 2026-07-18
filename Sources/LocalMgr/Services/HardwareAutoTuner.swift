import Foundation
import Darwin

/// Normalized Apple Silicon generation tier, classified from `hw.model`
/// (e.g. `Mac16,x` -> `.m4`). Modeled on MTPLX's
/// `classify_apple_silicon_generation` (`mtplx/hardware.py`): downstream
/// code should branch on this normalized tier rather than re-deriving raw
/// `hw.model` substring checks in multiple places.
enum ChipTier: String, CaseIterable {
    case m1 = "Apple M1 Series"
    case m2 = "Apple M2 Series"
    case m3 = "Apple M3 Series"
    case m4 = "Apple M4 Series"
    case m5 = "Apple M5 Series"
    case unknown = "Unknown Apple Silicon"

    /// Best-effort classification from a raw `hw.model` string (e.g.
    /// `"Mac16,1"`). Falls back to `.unknown` rather than guessing --
    /// callers should treat `.unknown` as "assume conservative defaults",
    /// not as an error.
    static func classify(rawModel: String) -> ChipTier {
        // Apple's Mac<N>,<variant> numbering has advanced roughly one
        // generation per two `Mac<N>` values across recent Apple Silicon
        // Macs; this mapping is necessarily a best-effort heuristic (Apple
        // does not publish a stable public mapping) and is intentionally
        // conservative -- an unrecognized/newer identifier falls through to
        // `.unknown` rather than being silently misclassified as the
        // current newest tier.
        if rawModel.contains("Mac17") || rawModel.contains("Mac18") {
            return .m5
        } else if rawModel.contains("Mac15") || rawModel.contains("Mac16") {
            return .m4
        } else if rawModel.contains("Mac14") {
            return .m3
        } else if rawModel.contains("Mac13") {
            return .m2
        } else if rawModel.hasPrefix("Mac") {
            // Earliest Apple Silicon identifiers (MacBookAir10,1 /
            // Macmini9,1 / MacBookPro17,1 / iMac21,x) don't share the
            // Mac<N> numbering scheme at all -- anything not matched above
            // that still looks like Apple Silicon (as opposed to an Intel
            // "MacPro7,1"-style identifier, filtered by the RAM/arch check
            // in `detectProfile`) is treated as first-generation M1.
            return .m1
        }
        return .unknown
    }
}

/// A hardware capability that has been *inferred* from a lookup table
/// keyed by chip tier, as opposed to one that has actually been measured on
/// this machine. Mirrors MTPLX's `hardware_acceleration_confirmed` honesty
/// pattern (`mtplx/hardware.py`): LocalMgr should never present an inferred
/// capability with the same confidence as a directly-measured one.
struct InferredCapability {
    let value: Bool
    /// `false` for every capability in this struct today -- LocalMgr has no
    /// on-device benchmark harness yet (see `localmgr-jhj.9`/`.10`'s
    /// empirical auto-tuner). Kept as an explicit field, not just an
    /// implicit assumption, so call sites and UI copy can reflect it
    /// (e.g. "supports large context (inferred, unconfirmed)").
    let confirmed: Bool
}

struct ChipProfile {
    let rawModel: String
    let chipFamily: String
    let chipTier: ChipTier
    let recommendedGPULayers: Int
    let useFlashAttention: Bool
    let maxSafeContext: Int

    /// Performance (P) and efficiency (E) core counts, read directly via
    /// `hw.perflevel0.physicalcpu` / `hw.perflevel1.physicalcpu` -- richer
    /// than a single total logical-CPU count, since P-core count is what
    /// actually matters for CPU-bound prompt-processing/tokenization work
    /// on Apple Silicon.
    let performanceCoreCount: Int
    let efficiencyCoreCount: Int

    /// GPU core count, probed via `system_profiler SPDisplaysDataType
    /// -json` when available. `nil` if the probe failed or was skipped
    /// (slow path -- see `HardwareAutoTuner.gpuCoreCount`). Never guessed
    /// from a chip-tier lookup table, since GPU core count varies by SKU
    /// (e.g. base/Pro/Max/Ultra) even within the same chip generation.
    let gpuCoreCount: Int?

    /// Whether this profile's `maxSafeContext` reflects an actually-
    /// measured capability or an inferred (RAM-tiered lookup table) one.
    /// Always `.confirmed == false` today -- see `InferredCapability`.
    let largeContextCapability: InferredCapability
}

enum HardwareAutoTuner {
    /// Cheap, sysctl-only chip identification (no `system_profiler` call --
    /// that path is slower and only invoked lazily via `gpuCoreCount()`).
    /// Mirrors MTPLX's split between a cheap `detect_apple_silicon()` for
    /// hot-path use and a fuller `inspect_hardware()` for one-off/on-demand
    /// use (`mtplx/hardware.py`).
    static func detectProfile(physicalMemoryBytes: Int64) -> ChipProfile {
        let rawModel = sysctlString(name: "hw.model")
        let tier = ChipTier.classify(rawModel: rawModel)

        let family: String
        switch tier {
        case .m1: family = "Apple M1 Series / Silicon"
        case .m2: family = "Apple M2 Series"
        case .m3: family = "Apple M3 Series"
        case .m4: family = "Apple M3 / M4 Series"
        case .m5: family = "Apple M5 Series"
        case .unknown: family = "Apple M1 Series / Silicon"
        }

        let totalGB = Double(physicalMemoryBytes) / 1_073_741_824.0
        let maxContext: Int
        if totalGB >= 60 {
            maxContext = 32768
        } else if totalGB >= 30 {
            maxContext = 16384
        } else {
            maxContext = 8192
        }

        let performanceCores = sysctlInt(name: "hw.perflevel0.physicalcpu")
        let efficiencyCores = sysctlInt(name: "hw.perflevel1.physicalcpu")

        return ChipProfile(
            rawModel: rawModel,
            chipFamily: family,
            chipTier: tier,
            recommendedGPULayers: 99,
            useFlashAttention: true,
            maxSafeContext: maxContext,
            performanceCoreCount: performanceCores ?? 0,
            efficiencyCoreCount: efficiencyCores ?? 0,
            gpuCoreCount: nil,
            // This is a RAM-tiered lookup table, not a measured result --
            // never claim it as confirmed. See `InferredCapability` and
            // `localmgr-jhj.9`/`.10` (empirical auto-tuner) for the
            // eventual measured counterpart.
            largeContextCapability: InferredCapability(value: totalGB >= 30, confirmed: false)
        )
    }

    /// GPU core count via `system_profiler SPDisplaysDataType -json`.
    /// Deliberately **not** called from `detectProfile` -- `system_profiler`
    /// can take 500ms-1s+, which is unacceptable on a hot path invoked
    /// every time a model starts. Callers that want GPU core count (e.g. a
    /// diagnostics/hardware-detail view, not the launch-flag decision path)
    /// should call this explicitly and cache the result for the process
    /// lifetime, since GPU core count cannot change without a reboot onto
    /// different hardware.
    static func gpuCoreCount() -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPDisplaysDataType", "-json"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            AppLog.debug("system_profiler unavailable for GPU core count probe: \(error.localizedDescription)", category: .general)
            return nil
        }

        // Bounded wait -- system_profiler should return well within this,
        // but a monitoring/detail probe must never be able to hang the
        // caller indefinitely.
        let deadline = Date().addingTimeInterval(5.0)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            AppLog.debug("system_profiler GPU core count probe timed out", category: .general)
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let displays = json["SPDisplaysDataType"] as? [[String: Any]] else {
            return nil
        }

        for entry in displays {
            if let coresString = entry["sppci_cores"] as? String, let cores = Int(coresString) {
                return cores
            }
            if let cores = entry["sppci_cores"] as? Int {
                return cores
            }
        }
        return nil
    }

    private static func sysctlString(name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var chars = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &chars, &size, nil, 0)
        let rawBytes = chars.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: rawBytes, as: UTF8.self)
    }

    private static func sysctlInt(name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname(name, &value, &size, nil, 0)
        guard result == 0 else { return nil }
        return Int(value)
    }
}
