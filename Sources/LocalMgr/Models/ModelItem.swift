import Foundation

enum EngineType: String, CaseIterable, Codable, Identifiable {
    case llamaCpp = "llama.cpp"
    case mlx = "MLX Engine"
    case kokoro = "Kokoro TTS"
    case gemmaCpp = "gemma.cpp"

    var id: String { rawValue }

    var defaultBinaryName: String {
        switch self {
        case .llamaCpp: return "llama-server"
        case .mlx: return "mlx_lm.server"
        case .kokoro: return "kokoro-server"
        case .gemmaCpp: return "gemma"
        }
    }

    var iconName: String {
        switch self {
        case .llamaCpp: return "terminal.fill"
        case .mlx: return "applelogo"
        case .kokoro: return "waveform"
        case .gemmaCpp: return "sparkles"
        }
    }
}

enum ModelFormat: String, Codable {
    case gguf = "GGUF"
    case mlx = "MLX Safetensors"
    case onnx = "ONNX Audio"
    case unknown = "Unknown"
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

    var sizeFormatted: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: sizeBytes)
    }
}
