import Foundation

struct GGUFMetadata {
    var quantization: String?
    var contextLength: Int?
}

enum GGUFHeaderParser {
    static func inspect(url: URL) -> GGUFMetadata {
        var meta = GGUFMetadata(quantization: "GGUF", contextLength: 8192)
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return meta }
        defer { try? fileHandle.close() }

        // Read first 1024 bytes to inspect GGUF magic and basic string markers if available
        guard let headerData = try? fileHandle.read(upToCount: 4096) else { return meta }
        
        let magic = String(data: headerData.prefix(4), encoding: .ascii)
        if magic != "GGUF" {
            return meta
        }

        // Fast string scan for common quantization indicators in filenames or header metadata strings
        let name = url.lastPathComponent.uppercased()
        let quants = ["Q4_K_M", "Q4_K_S", "Q5_K_M", "Q6_K", "Q8_0", "F16", "Q3_K_M", "Q4_0"]
        for q in quants {
            if name.contains(q) {
                meta.quantization = q
                break
            }
        }

        return meta
    }
}
