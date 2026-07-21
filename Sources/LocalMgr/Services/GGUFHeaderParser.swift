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

enum GGUFValue {
    case uint8(UInt8)
    case int8(Int8)
    case uint16(UInt16)
    case int16(Int16)
    case uint32(UInt32)
    case int32(Int32)
    case float32(Float)
    case bool(Bool)
    case string(String)
    indirect case array(UInt32, [GGUFValue])
    case uint64(UInt64)
    case int64(Int64)
    case float64(Double)
}

struct GGUFBinaryReader {
    let data: Data
    var offset: Int = 0

    mutating func readBytes(_ count: Int) -> Data? {
        guard offset + count <= data.count else { return nil }
        let sub = data.subdata(in: offset..<offset + count)
        offset += count
        return sub
    }

    mutating func readUInt16() -> UInt16? {
        guard let bytes = readBytes(2) else { return nil }
        return bytes.withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
    }

    mutating func readInt16() -> Int16? {
        guard let bytes = readBytes(2) else { return nil }
        return bytes.withUnsafeBytes { $0.load(as: Int16.self) }.littleEndian
    }

    mutating func readUInt32() -> UInt32? {
        guard let bytes = readBytes(4) else { return nil }
        return bytes.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
    }

    mutating func readInt32() -> Int32? {
        guard let bytes = readBytes(4) else { return nil }
        return bytes.withUnsafeBytes { $0.load(as: Int32.self) }.littleEndian
    }

    mutating func readUInt64() -> UInt64? {
        guard let bytes = readBytes(8) else { return nil }
        return bytes.withUnsafeBytes { $0.load(as: UInt64.self) }.littleEndian
    }

    mutating func readInt64() -> Int64? {
        guard let bytes = readBytes(8) else { return nil }
        return bytes.withUnsafeBytes { $0.load(as: Int64.self) }.littleEndian
    }

    mutating func readFloat32() -> Float? {
        guard let bytes = readBytes(4) else { return nil }
        return bytes.withUnsafeBytes { $0.load(as: Float.self) }
    }

    mutating func readFloat64() -> Double? {
        guard let bytes = readBytes(8) else { return nil }
        return bytes.withUnsafeBytes { $0.load(as: Double.self) }
    }

    mutating func readString() -> String? {
        guard let len = readUInt64() else { return nil }
        guard offset + Int(len) <= data.count else { return nil }
        let strData = data.subdata(in: offset..<offset + Int(len))
        offset += Int(len)
        return String(data: strData, encoding: .utf8)
    }

    mutating func readValue(type: UInt32) -> GGUFValue? {
        switch type {
        case 0:
            guard offset + 1 <= data.count else { return nil }
            let v = data[offset]
            offset += 1
            return .uint8(v)
        case 1:
            guard offset + 1 <= data.count else { return nil }
            let v = Int8(bitPattern: data[offset])
            offset += 1
            return .int8(v)
        case 2:
            guard let v = readUInt16() else { return nil }
            return .uint16(v)
        case 3:
            guard let v = readInt16() else { return nil }
            return .int16(v)
        case 4:
            guard let v = readUInt32() else { return nil }
            return .uint32(v)
        case 5:
            guard let v = readInt32() else { return nil }
            return .int32(v)
        case 6:
            guard let v = readFloat32() else { return nil }
            return .float32(v)
        case 7:
            guard offset + 1 <= data.count else { return nil }
            let v = data[offset] != 0
            offset += 1
            return .bool(v)
        case 8:
            guard let s = readString() else { return nil }
            return .string(s)
        case 10:
            guard let v = readUInt64() else { return nil }
            return .uint64(v)
        case 11:
            guard let v = readInt64() else { return nil }
            return .int64(v)
        case 12:
            guard let v = readFloat64() else { return nil }
            return .float64(v)
        case 9:
            guard let elemType = readUInt32(),
                  let count = readUInt64() else { return nil }
            var arr: [GGUFValue] = []
            // Protect against extremely large count allocations
            guard count < 10000 else {
                // If it's a huge array (like vocab token list), we don't need to parse every single element.
                // Just skip the bytes to stay byte-aligned.
                offset -= 12 // roll back readUInt32 and readUInt64
                if skipValue(type: 9) {
                    return .array(elemType, [])
                }
                return nil
            }
            for _ in 0..<count {
                guard let val = readValue(type: elemType) else { return nil }
                arr.append(val)
            }
            return .array(elemType, arr)
        default:
            return nil
        }
    }

    mutating func skipValue(type: UInt32) -> Bool {
        switch type {
        case 0, 1, 7:
            offset += 1
            return offset <= data.count
        case 2, 3:
            offset += 2
            return offset <= data.count
        case 4, 5, 6:
            offset += 4
            return offset <= data.count
        case 10, 11, 12:
            offset += 8
            return offset <= data.count
        case 8:
            guard let len = readUInt64() else { return false }
            offset += Int(len)
            return offset <= data.count
        case 9:
            guard let elemType = readUInt32(),
                  let count = readUInt64() else { return false }
            // If it's a huge array, skip by element size if possible to avoid recursing deeply
            let scalarSizes: [UInt32: Int] = [0:1, 1:1, 2:2, 3:2, 4:4, 5:4, 6:4, 7:1, 10:8, 11:8, 12:8]
            if let sz = scalarSizes[elemType] {
                offset += sz * Int(count)
                return offset <= data.count
            }
            for _ in 0..<count {
                if !skipValue(type: elemType) { return false }
            }
            return true
        default:
            return false
        }
    }
}

enum GGUFHeaderParser {
    static func inspect(url: URL) -> GGUFMetadata {
        var meta = GGUFMetadata(
            quantization: "GGUF",
            contextLength: 8192,
            layerCount: 32,
            embeddingLength: 4096,
            headCountKV: 8,
            chatTemplate: nil,
            isValidGGUF: false,
            architectureMarker: nil
        )
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return meta }
        defer { try? fileHandle.close() }

        // Read up to 256KB to make sure we parse all metadata keys including chat templates and arrays
        guard let headerData = try? fileHandle.read(upToCount: 262144) else { return meta }
        
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

        var reader = GGUFBinaryReader(data: headerData)
        // Skip magic(4)
        _ = reader.readBytes(4)

        guard let version = reader.readUInt32(),
              version >= 2,
              let _ = reader.readUInt64(), // tensorCount (unused for meta)
              let kvCount = reader.readUInt64() else {
            return meta
        }

        var architecture: String? = nil
        var kvs: [String: GGUFValue] = [:]

        // Read KV pairs sequentially
        for _ in 0..<kvCount {
            guard let key = reader.readString(),
                  let vtype = reader.readUInt32(),
                  let val = reader.readValue(type: vtype) else {
                break
            }
            kvs[key] = val
        }

        // 1. Extract general.architecture
        if let archVal = kvs["general.architecture"] {
            switch archVal {
            case .string(let arch):
                architecture = arch
                meta.architectureMarker = arch
            default:
                break
            }
        }

        // 2. Extract tokenizer.chat_template
        if let templateVal = kvs["tokenizer.chat_template"] {
            switch templateVal {
            case .string(let tmpl):
                if tmpl.contains("<start_of_turn>") {
                    meta.chatTemplate = "Gemma (<start_of_turn>)"
                } else if tmpl.contains("<|eot_id|>") {
                    meta.chatTemplate = "Llama 3 (<|eot_id|>)"
                } else if tmpl.contains("<|im_start|>") {
                    meta.chatTemplate = "ChatML (<|im_start|>)"
                } else if tmpl.contains("[INST]") {
                    meta.chatTemplate = "Mistral / Llama 2 ([INST])"
                } else {
                    meta.chatTemplate = "Custom Jinja Template"
                }
            default:
                break
            }
        }

        // Helper helper to get Int value from GGUFValue scalars
        func getIntVal(_ val: GGUFValue) -> Int? {
            switch val {
            case .uint8(let v): return Int(v)
            case .int8(let v): return Int(v)
            case .uint16(let v): return Int(v)
            case .int16(let v): return Int(v)
            case .uint32(let v): return Int(v)
            case .int32(let v): return Int(v)
            case .uint64(let v): return Int(v)
            case .int64(let v): return Int(v)
            default: return nil
            }
        }

        // 3. Extract architecture-specific properties
        if let arch = architecture {
            if let ctxVal = kvs["\(arch).context_length"], let intVal = getIntVal(ctxVal) {
                meta.contextLength = intVal
            }
            if let blockVal = kvs["\(arch).block_count"], let intVal = getIntVal(blockVal) {
                meta.layerCount = intVal
            }
            if let embVal = kvs["\(arch).embedding_length"], let intVal = getIntVal(embVal) {
                meta.embeddingLength = intVal
            }
            if let kvVal = kvs["\(arch).attention.head_count_kv"], let intVal = getIntVal(kvVal) {
                meta.headCountKV = intVal
            }
        }

        // Secondary fallback checking for backward compatibility/corrupt headers
        if meta.chatTemplate == nil || meta.architectureMarker == nil {
            if let asciiDump = String(data: headerData, encoding: .ascii) ?? String(data: headerData, encoding: .utf8) {
                if meta.architectureMarker == nil {
                    if asciiDump.contains("gemma2") {
                        meta.architectureMarker = "gemma2"
                    } else if asciiDump.contains("gemma") {
                        meta.architectureMarker = "gemma"
                    } else if asciiDump.contains("llama-3") || asciiDump.contains("llama3") {
                        meta.architectureMarker = "llama-3"
                    }
                }
                
                if meta.chatTemplate == nil {
                    if asciiDump.contains("<start_of_turn>") {
                        meta.chatTemplate = "Gemma (<start_of_turn>)"
                    } else if asciiDump.contains("<|eot_id|>") {
                        meta.chatTemplate = "Llama 3 (<|eot_id|>)"
                    } else if asciiDump.contains("<|im_start|>") {
                        meta.chatTemplate = "ChatML (<|im_start|>)"
                    } else if asciiDump.contains("[INST]") {
                        meta.chatTemplate = "Mistral / Llama 2 ([INST])"
                    }
                }
            }
        }

        return meta
    }
}
