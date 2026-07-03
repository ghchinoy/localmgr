import Foundation
import Darwin

struct ChipProfile {
    let rawModel: String
    let chipFamily: String
    let recommendedGPULayers: Int
    let useFlashAttention: Bool
    let maxSafeContext: Int
}

enum HardwareAutoTuner {
    static func detectProfile(physicalMemoryBytes: Int64) -> ChipProfile {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var modelChars = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &modelChars, &size, nil, 0)
        let rawBytes = modelChars.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        let rawModel = String(decoding: rawBytes, as: UTF8.self)

        let family: String
        if rawModel.contains("Mac15") || rawModel.contains("Mac16") {
            family = "Apple M3 / M4 Series"
        } else if rawModel.contains("Mac14") {
            family = "Apple M2 Series"
        } else {
            family = "Apple M1 Series / Silicon"
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

        return ChipProfile(
            rawModel: rawModel,
            chipFamily: family,
            recommendedGPULayers: 99,
            useFlashAttention: true,
            maxSafeContext: maxContext
        )
    }
}
