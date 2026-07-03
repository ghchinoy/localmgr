import Foundation

enum EngineType: String, CaseIterable, Codable, Identifiable {
    case llamaCpp = "llama.cpp"
    case mlx = "MLX Engine"
    case kokoro = "Kokoro TTS"
    case gemmaCpp = "gemma.cpp"
    case liteRT = "LiteRT Engine"

    var id: String { rawValue }

    var defaultBinaryName: String {
        switch self {
        case .llamaCpp: return "llama-server"
        case .mlx: return "mlx_lm.server"
        case .kokoro: return "kokoro-server"
        case .gemmaCpp: return "gemma"
        case .liteRT: return "litert-lm"
        }
    }

    var iconName: String {
        switch self {
        case .llamaCpp: return "terminal.fill"
        case .mlx: return "applelogo"
        case .kokoro: return "waveform"
        case .gemmaCpp: return "sparkles"
        case .liteRT: return "cube.transparent.fill"
        }
    }
}

enum ModelFormat: String, Codable {
    case gguf = "GGUF"
    case mlx = "MLX Safetensors"
    case onnx = "ONNX Audio"
    case liteRT = "LiteRT (.tflite)"
    case unknown = "Unknown"
}

struct MemoryPressureBreakdown {
    let weightsRAMBytes: Int64
    let kvCacheRAMBytes: Int64
    let totalRequiredBytes: Int64

    var formattedWeights: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: weightsRAMBytes)
    }

    var formattedKVCache: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: kvCacheRAMBytes)
    }

    var formattedTotal: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalRequiredBytes)
    }
}

struct ModelItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let fileURL: URL
    let format: ModelFormat
    let sizeBytes: Int64
    let engineType: EngineType
    var quantization: String?
    var contextLength: Int?
    var layerCount: Int?
    var headCountKV: Int?
    var chatTemplate: String?

    var sizeFormatted: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: sizeBytes)
    }

    func memoryPressure(forContextLength ctx: Int = 8192) -> MemoryPressureBreakdown {
        let weights = sizeBytes
        // FP16/FP8 KV Cache estimation per token:
        // bytes_per_token ≈ 2 (K&V) * 2 (bytes in FP16) * layerCount * headCountKV * head_dim (128 default)
        let layers = Int64(layerCount ?? 32)
        let kvHeads = Int64(headCountKV ?? 8)
        let bytesPerToken = 4 * layers * kvHeads * 128
        let kvCacheSize = bytesPerToken * Int64(ctx)
        let total = weights + kvCacheSize
        return MemoryPressureBreakdown(weightsRAMBytes: weights, kvCacheRAMBytes: kvCacheSize, totalRequiredBytes: total)
    }
}
