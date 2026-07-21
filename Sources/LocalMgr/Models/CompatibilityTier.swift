import Foundation

/// A graduated signal for how confident LocalMgr is that a scanned model
/// file will actually run correctly with its assigned engine, distinct
/// from `EngineComponentStatus.isInstalled` (which only answers "is the
/// engine binary present on this machine at all").
///
/// Modeled on MTPLX's 5-tier `backends/registry.py` compatibility
/// classification (verified / family-compatible-unverified /
/// architecture-compatible-but-unverified / incompatible-architecture /
/// no-MTP-equivalent), collapsed to the 4 tiers that make sense for
/// LocalMgr's simpler "does this file's header look like a model this
/// engine understands" scanning (LocalMgr does not train/verify per-model
/// runtime contracts the way MTPLX's Forge pipeline does).
enum CompatibilityTier: String, Codable {
    /// The file's architecture/quantization/chat-template markers were
    /// recognized and match a combination LocalMgr has explicit knowledge
    /// of for the assigned engine.
    case verified = "Verified"

    /// The file parses as a known format (e.g. valid GGUF magic) and its
    /// architecture string was recognized, but this specific
    /// architecture+quantization+engine combination is not one LocalMgr
    /// has explicit knowledge of -- it will likely run, but hasn't been
    /// specifically confirmed.
    case recognizedUnverified = "Recognized (Unverified)"

    /// The file parses as a known format, but its architecture string
    /// (or, for MLX, its `config.json` `model_type`) was not recognized at
    /// all.
    case unrecognizedArchitecture = "Unrecognized Architecture"

    /// The file's header/magic bytes could not be parsed as the expected
    /// format at all (e.g. missing "GGUF" magic, corrupt/truncated file).
    case unparseable = "Unparseable"

    /// A short status label suitable for a compact UI badge.
    var badgeLabel: String {
        switch self {
        case .verified: return "Verified"
        case .recognizedUnverified: return "Unverified"
        case .unrecognizedArchitecture: return "Unrecognized"
        case .unparseable: return "Unparseable"
        }
    }

    var symbolName: String {
        switch self {
        case .verified: return "checkmark.seal.fill"
        case .recognizedUnverified: return "questionmark.circle.fill"
        case .unrecognizedArchitecture: return "exclamationmark.triangle.fill"
        case .unparseable: return "xmark.octagon.fill"
        }
    }

    var isConcerning: Bool {
        self != .verified
    }
}

/// A small set of architecture identifiers LocalMgr has explicit knowledge
/// of per engine, used to compute `CompatibilityTier`. This is
/// intentionally a short, hand-curated allowlist (mirroring MTPLX's
/// `ARCHITECTURE_CATALOG`) rather than an attempt to enumerate every
/// architecture llama.cpp/MLX support -- anything not on the list is
/// `.recognizedUnverified`, not `.unrecognizedArchitecture`, as long as
/// *some* architecture string was found at all.
enum ModelCompatibilityClassifier {
    /// GGUF architecture strings (as embedded in the `general.architecture`
    /// metadata key / detectable via chat-template markers) that LocalMgr
    /// has specifically exercised with `llama-server`.
    private static let verifiedGGUFArchitectureMarkers: Set<String> = [
        // Gemma family
        "gemma", "gemma2", "gemma4",
        // Llama family
        "llama", "llama-3", "llama3",
        // Mistral family
        "mistral",
        // Cohere family
        "command-r", "cohere2moe",
        // Qwen family
        "qwen2", "qwen2moe",
        // Phi family
        "phi3", "phi4",
        // DeepSeek family
        "deepseek2",
        // StarCoder / coding
        "starcoder2",
        // Other confirmed
        "falcon", "mpt", "bert", "nomic-bert"
    ]

    /// Classifies a scanned GGUF file using the metadata already extracted
    /// by `GGUFHeaderParser`, without a second file read.
    ///
    /// - Parameters:
    ///   - isValidGGUF: Whether the "GGUF" magic bytes were present.
    ///   - architectureMarker: A short lowercase token identifying the
    ///     detected architecture family, if any (e.g. `"gemma"`,
    ///     `"llama-3"`), or `nil` if no known marker was found in the
    ///     header/chat-template scan.
    static func classifyGGUF(isValidGGUF: Bool, architectureMarker: String?) -> (tier: CompatibilityTier, message: String, recommendedAction: String?) {
        guard isValidGGUF else {
            return (
                .unparseable,
                "This file does not have a valid GGUF header (missing \"GGUF\" magic bytes).",
                "Re-download the file -- it may be truncated or corrupted, or it may not actually be a GGUF model."
            )
        }

        guard let marker = architectureMarker else {
            return (
                .unrecognizedArchitecture,
                "This is a valid GGUF file, but LocalMgr could not identify its model architecture from the header or chat template markers.",
                "llama-server may still be able to run it -- try starting it and check Live Logs for the architecture it reports. If it fails to load, this architecture likely needs a newer llama.cpp build."
            )
        }

        if verifiedGGUFArchitectureMarkers.contains(marker) {
            return (.verified, "Architecture '\(marker)' is recognized and has been verified with llama-server.", nil)
        }

        return (
            .recognizedUnverified,
            "Architecture '\(marker)' was detected, but this exact architecture/llama-server combination has not been specifically verified by LocalMgr.",
            "It will likely run correctly -- llama.cpp supports a broad range of architectures. If it fails to load or produces garbled output, check for a newer llama-server build."
        )
    }

    /// Classifies a scanned MLX model directory. MLX packages are
    /// identified by folder heuristics in `ModelCatalogService` (a
    /// `config.json` alongside `.safetensors` files) rather than a binary
    /// header, so there is no "unparseable" case here -- by the time this
    /// is called, the directory has already been confirmed to look like an
    /// MLX package.
    static func classifyMLX(modelType: String?) -> (tier: CompatibilityTier, message: String, recommendedAction: String?) {
        guard let modelType, !modelType.isEmpty else {
            return (
                .unrecognizedArchitecture,
                "This MLX package's config.json does not declare a recognizable \"model_type\".",
                "mlx_lm.server may still load it -- start it and check Live Logs. If it fails, this architecture may need a newer mlx-lm release."
            )
        }
        // LocalMgr does not currently parse MLX config.json model_type
        // beyond presence -- treat any declared type as recognized-but-
        // unverified rather than claiming false confidence.
        return (
            .recognizedUnverified,
            "MLX model_type '\(modelType)' was declared, but LocalMgr has not specifically verified this architecture against the installed mlx-lm version.",
            nil
        )
    }
}
