import Foundation

struct GGUFMetadata {
    var quantization: String?
    var contextLength: Int?
    var layerCount: Int?
    var embeddingLength: Int?
    var headCountKV: Int?
    var chatTemplate: String?

    /// Whether the "GGUF" magic bytes were present at the start of the
    /// file. `false` means the file could not be parsed as GGUF at all
    /// (corrupt/truncated/misnamed), which `ModelCompatibilityClassifier`
    /// surfaces as `.unparseable` rather than silently falling back to
    /// generic defaults.
    var isValidGGUF: Bool = false

    /// A short, lowercase architecture-family token detected from the
    /// header/chat-template scan (e.g. `"gemma"`, `"llama-3"`), or `nil` if
    /// none of the known markers matched. Feeds
    /// `ModelCompatibilityClassifier.classifyGGUF`.
    var architectureMarker: String?
}

enum GGUFHeaderParser {
    static func inspect(url: URL) -> GGUFMetadata {
        var meta = GGUFMetadata(quantization: "GGUF", contextLength: 8192, layerCount: 32, embeddingLength: 4096, headCountKV: 8, chatTemplate: nil)
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return meta }
        defer { try? fileHandle.close() }

        guard let headerData = try? fileHandle.read(upToCount: 131072) else { return meta }
        
        let magic = String(data: headerData.prefix(4), encoding: .ascii)
        guard magic == "GGUF" else {
            return meta
        }
        meta.isValidGGUF = true

        let name = url.lastPathComponent.uppercased()
        let quants = ["Q4_K_M", "Q4_K_S", "Q5_K_M", "Q6_K", "Q8_0", "F16", "Q3_K_M", "Q4_0"]
        for q in quants {
            if name.contains(q) {
                meta.quantization = q
                break
            }
        }

        if let asciiDump = String(data: headerData, encoding: .ascii) ?? String(data: headerData, encoding: .utf8) {
            if asciiDump.contains("gemma2") || asciiDump.contains("gemma") || asciiDump.contains("<start_of_turn>") {
                meta.contextLength = 8192
                meta.chatTemplate = "Gemma (<start_of_turn>)"
                meta.architectureMarker = "gemma"
                if name.contains("27B") {
                    meta.layerCount = 46
                    meta.headCountKV = 16
                } else {
                    meta.layerCount = 42
                    meta.headCountKV = 8
                }
            } else if asciiDump.contains("llama-3") || asciiDump.contains("llama3") || asciiDump.contains("<|eot_id|>") {
                meta.contextLength = 8192
                meta.layerCount = 32
                meta.headCountKV = 8
                meta.chatTemplate = "Llama 3 (<|eot_id|>)"
                meta.architectureMarker = "llama-3"
            } else if asciiDump.contains("<|im_start|>") {
                meta.chatTemplate = "ChatML (<|im_start|>)"
            } else if asciiDump.contains("[INST]") {
                meta.chatTemplate = "Mistral / Llama 2 ([INST])"
            }
        }

        return meta
    }
}
