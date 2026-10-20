import Foundation
import Combine
import AppKit

@MainActor
class ModelCatalogService: ObservableObject {
    enum ModelFilterCategory: String, CaseIterable, Identifiable {
        case all = "All"
        case gguf = "GGUF"
        case mlx = "MLX"
        case liteRT = "LiteRT"
        case audio = "Audio/TTS"
        var id: String { rawValue }
    }

    enum ModelSortOption: String, CaseIterable, Identifiable {
        case scanOrder = "Scan Order"
        case name = "Alphabetical"
        case size = "Size"
        case lastUsed = "Last Run"
        case mostFrequent = "Most Frequent"
        
        var id: String { rawValue }
    }

    @Published var folders: [URL] = []
    @Published var models: [ModelItem] = []
    @Published var selectedModel: ModelItem?
    @Published var searchText: String = ""
    @Published var selectedFilter: ModelFilterCategory = .all
    @Published var selectedSortOption: ModelSortOption = .scanOrder

    private let bookmarksKey = "LocalMgrFolderBookmarks"
    private let folderPathsKey = "LocalMgrFolderPaths"

    var filteredModels: [ModelItem] {
        var list = models
        switch selectedFilter {
        case .all: break
        case .gguf: list = list.filter { $0.format == .gguf }
        case .mlx: list = list.filter { $0.format == .mlx }
        case .liteRT: list = list.filter { $0.format == .liteRT }
        case .audio: list = list.filter { $0.format == .onnx || $0.engineType == .kokoro }
        }

        if !searchText.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }

        switch selectedSortOption {
        case .scanOrder:
            break
        case .name:
            list.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .size:
            list.sort { $0.sizeBytes > $1.sizeBytes }
        case .lastUsed:
            let lastUsed = UserDefaults.standard.dictionary(forKey: "LocalMgrModelLastUsedDates") as? [String: Double] ?? [:]
            list.sort {
                let t1 = lastUsed[$0.fileURL.path] ?? 0
                let t2 = lastUsed[$1.fileURL.path] ?? 0
                if t1 != t2 {
                    return t1 > t2
                }
                return $0.name.localizedCompare($1.name) == .orderedAscending
            }
        case .mostFrequent:
            let counts = UserDefaults.standard.dictionary(forKey: "LocalMgrModelUsageCounts") as? [String: Int] ?? [:]
            list.sort {
                let c1 = counts[$0.fileURL.path] ?? 0
                let c2 = counts[$1.fileURL.path] ?? 0
                if c1 != c2 {
                    return c1 > c2
                }
                return $0.name.localizedCompare($1.name) == .orderedAscending
            }
        }

        return list
    }

    init() {
        loadBookmarkedFolders()
        refreshCatalog()
    }

    func promptAddFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Model Folder"
        panel.message = "Select a directory containing GGUF or MLX models"

        if panel.runModal() == .OK {
            for url in panel.urls {
                addFolder(url)
            }
        }
    }

    func addFolder(_ url: URL) {
        guard !folders.contains(url) else { return }
        do {
            let bookmarkData = try (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
                ?? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            var existing = UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] ?? []
            existing.append(bookmarkData)
            UserDefaults.standard.set(existing, forKey: bookmarksKey)
        } catch {
            AppLog.error("Failed to save security-scoped bookmark for folder '\(url.lastPathComponent)': \(error.localizedDescription)", category: .catalog)
        }

        var savedPaths = UserDefaults.standard.stringArray(forKey: folderPathsKey) ?? []
        if !savedPaths.contains(url.path) {
            savedPaths.append(url.path)
            UserDefaults.standard.set(savedPaths, forKey: folderPathsKey)
        }

        _ = url.startAccessingSecurityScopedResource()
        folders.append(url)
        refreshCatalog()
    }

    private func loadBookmarkedFolders() {
        var seenPaths = Set<String>()
        if let bookmarkDataArray = UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] {
            for data in bookmarkDataArray {
                var isStale = false
                if let url = (try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale))
                    ?? (try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale)) {
                    _ = url.startAccessingSecurityScopedResource()
                    if seenPaths.insert(url.standardizedFileURL.path).inserted {
                        folders.append(url)
                    }
                } else {
                    AppLog.error("Failed to resolve a saved folder bookmark.", category: .catalog)
                }
            }
        }
        if let savedPaths = UserDefaults.standard.stringArray(forKey: folderPathsKey) {
            for path in savedPaths where FileManager.default.fileExists(atPath: path) {
                let url = URL(fileURLWithPath: path)
                if seenPaths.insert(url.standardizedFileURL.path).inserted {
                    folders.append(url)
                }
            }
        }
    }

    func refreshCatalog() {
        self.models = Self.scanFolders(folders)
    }

    struct MLXConfigMetadata: Equatable {
        let modelType: String?
        let quantization: String
        let contextLength: Int
        let layerCount: Int
        let headCountKV: Int
    }

    /// Resolves all symbolic links (including multi-hop and relative symlinks
    /// inside symlinked parent directories, such as `../gemma/mlx-gemma-4-e2b/config.json`
    /// -> `snapshots/<sha>/config.json` -> `../../blobs/<hash>`) using POSIX `realpath`.
    nonisolated static func realpathURL(for url: URL) -> URL {
        if let resolvedC = Darwin.realpath(url.path, nil) {
            defer { free(resolvedC) }
            let path = String(cString: resolvedC)
            return URL(fileURLWithPath: path)
        }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    nonisolated static func inspectMLXConfig(at configURL: URL) -> MLXConfigMetadata {
        let resolvedURL = realpathURL(for: configURL)
        guard let data = try? Data(contentsOf: resolvedURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return MLXConfigMetadata(
                modelType: nil,
                quantization: "MLX-Safetensors",
                contextLength: 32768,
                layerCount: 32,
                headCountKV: 8
            )
        }

        let textConfig = json["text_config"] as? [String: Any]

        let modelType = (json["model_type"] as? String)
            ?? (textConfig?["model_type"] as? String)

        let contextLength = (json["max_position_embeddings"] as? Int)
            ?? (textConfig?["max_position_embeddings"] as? Int)
            ?? (json["max_sequence_length"] as? Int)
            ?? (textConfig?["max_sequence_length"] as? Int)
            ?? 32768

        let layerCount = (json["num_hidden_layers"] as? Int)
            ?? (textConfig?["num_hidden_layers"] as? Int)
            ?? (json["n_layers"] as? Int)
            ?? 32

        let headCountKV = (json["num_key_value_heads"] as? Int)
            ?? (textConfig?["num_key_value_heads"] as? Int)
            ?? (json["num_attention_heads"] as? Int)
            ?? (textConfig?["num_attention_heads"] as? Int)
            ?? 8

        var quantization = "MLX-Safetensors"
        if let quantDict = (json["quantization"] as? [String: Any]) ?? (json["quantization_config"] as? [String: Any]),
           let bits = quantDict["bits"] as? Int {
            quantization = "MLX-\(bits)bit"
        }

        return MLXConfigMetadata(
            modelType: modelType,
            quantization: quantization,
            contextLength: contextLength,
            layerCount: layerCount,
            headCountKV: headCountKV
        )
    }

    /// Recursively enumerates files across `rootFolder`, following directory
    /// symlinks (such as `../gemma/mlx-gemma-4-e2b -> ~/.cache/huggingface/hub/...`)
    /// while tracking canonical directory paths in `visitedDirectories` to prevent
    /// symlink cycles and duplicate scans (localmgr-n3n).
    nonisolated private static func enumerateFilesFollowingSymlinks(
        in rootFolder: URL,
        visitedDirectories: inout Set<String>
    ) -> [URL] {
        let fileManager = FileManager.default
        var collected: [URL] = []

        func walk(_ directory: URL) {
            let resolvedDirURL = realpathURL(for: directory)
            let canonicalDir = resolvedDirURL.path
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: canonicalDir, isDirectory: &isDir), isDir.boolValue else {
                return
            }
            guard visitedDirectories.insert(canonicalDir).inserted else {
                return
            }
            guard let entryNames = try? fileManager.contentsOfDirectory(atPath: canonicalDir) else {
                return
            }
            let sortedNames = entryNames
                .filter { !$0.hasPrefix(".") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

            for name in sortedNames {
                let logicalEntry = directory.appendingPathComponent(name)
                let resolvedEntryPath = realpathURL(for: logicalEntry).path
                var entryIsDir: ObjCBool = false
                guard fileManager.fileExists(atPath: resolvedEntryPath, isDirectory: &entryIsDir) else {
                    // Broken/dangling symlink -> skip cleanly
                    continue
                }
                if entryIsDir.boolValue {
                    walk(logicalEntry)
                } else {
                    collected.append(logicalEntry)
                }
            }
        }

        walk(rootFolder)
        return collected
    }

    /// Resolves the byte size of `fileURL`, following symlinks (e.g. Hugging Face
    /// `snapshots/<sha>/*.safetensors -> ../../blobs/<hash>`) so symlinked weight
    /// files report their true size rather than the symlink's own byte length.
    nonisolated static func resolvedFileSize(for fileURL: URL) -> Int64 {
        let resolved = realpathURL(for: fileURL)
        if let size = try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return Int64(size)
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path),
           let num = attrs[.size] as? NSNumber {
            return num.int64Value
        }
        return 0
    }

    /// Derives a human-friendly display name for an MLX model directory.
    /// Preserves the directory or symlink name (e.g. `mlx-gemma-4-e2b`), unless
    /// the directory is a raw Hugging Face `snapshots/<sha>` folder, in which
    /// case it extracts the repo name from `models--<org>--<repo>`.
    nonisolated static func friendlyMLXFolderName(for parentURL: URL) -> String {
        if parentURL.deletingLastPathComponent().lastPathComponent == "snapshots" {
            let repoDir = parentURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            if repoDir.hasPrefix("models--") {
                return String(repoDir.dropFirst("models--".count)).replacingOccurrences(of: "--", with: "/")
            }
        }
        return parentURL.lastPathComponent
    }

    nonisolated static func scanFolders(_ folders: [URL]) -> [ModelItem] {
        var scanned: [ModelItem] = []
        let fileManager = FileManager.default
        var visitedDirectories = Set<String>()
        var visitedFiles = Set<String>()

        for folder in folders {
            let files = enumerateFilesFollowingSymlinks(in: folder, visitedDirectories: &visitedDirectories)

            for fileURL in files {
                let canonicalFile = realpathURL(for: fileURL).path
                let ext = fileURL.pathExtension.lowercased()

                if ext == "gguf" {
                    guard visitedFiles.insert(canonicalFile).inserted else { continue }
                    let size = resolvedFileSize(for: fileURL)
                    let headerInfo = GGUFHeaderParser.inspect(url: realpathURL(for: fileURL))
                    var item = ModelItem(
                        name: fileURL.deletingPathExtension().lastPathComponent,
                        fileURL: fileURL,
                        format: .gguf,
                        sizeBytes: size,
                        engineType: .llamaCpp,
                        quantization: headerInfo.quantization,
                        contextLength: headerInfo.contextLength,
                        layerCount: headerInfo.layerCount,
                        headCountKV: headerInfo.headCountKV
                    )
                    let compat = ModelCompatibilityClassifier.classifyGGUF(
                        isValidGGUF: headerInfo.isValidGGUF,
                        architectureMarker: headerInfo.architectureMarker
                    )
                    item.compatibilityTier = compat.tier
                    item.compatibilityMessage = compat.message
                    item.compatibilityRecommendedAction = compat.recommendedAction
                    scanned.append(item)
                } else if ["tflite", "tfl", "task", "litert", "litertlm"].contains(ext) {
                    guard visitedFiles.insert(canonicalFile).inserted else { continue }
                    let size = resolvedFileSize(for: fileURL)
                    let item = ModelItem(
                        name: fileURL.deletingPathExtension().lastPathComponent,
                        fileURL: fileURL,
                        format: .liteRT,
                        sizeBytes: size,
                        engineType: .liteRT,
                        quantization: "LiteRT-Quantized",
                        contextLength: 4096,
                        layerCount: 28,
                        headCountKV: 8
                    )
                    scanned.append(item)
                } else if fileURL.lastPathComponent == "config.json" {
                    guard visitedFiles.insert(canonicalFile).inserted else { continue }
                    // Check if parent directory represents an MLX package
                    let parentURL = fileURL.deletingLastPathComponent()
                    let resolvedParentPath = realpathURL(for: parentURL).path
                    let folderName = friendlyMLXFolderName(for: parentURL)
                    let hasSafetensors = (try? fileManager.contentsOfDirectory(atPath: resolvedParentPath).contains(where: { $0.hasSuffix(".safetensors") })) == true
                    if folderName.lowercased().contains("mlx") || hasSafetensors {
                        let size = calculateFolderSize(url: parentURL)
                        let mlxMeta = inspectMLXConfig(at: fileURL)
                        var item = ModelItem(
                            name: folderName,
                            fileURL: parentURL,
                            format: .mlx,
                            sizeBytes: size,
                            engineType: .mlx,
                            quantization: mlxMeta.quantization,
                            contextLength: mlxMeta.contextLength,
                            layerCount: mlxMeta.layerCount,
                            headCountKV: mlxMeta.headCountKV
                        )
                        let compat = ModelCompatibilityClassifier.classifyMLX(modelType: mlxMeta.modelType)
                        item.compatibilityTier = compat.tier
                        item.compatibilityMessage = compat.message
                        item.compatibilityRecommendedAction = compat.recommendedAction
                        scanned.append(item)
                    }
                }
            }
        }

        return scanned
    }

    nonisolated static func calculateFolderSize(url: URL) -> Int64 {
        var total: Int64 = 0
        let resolvedRoot = realpathURL(for: url)
        guard let enumerator = FileManager.default.enumerator(at: resolvedRoot, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) else { return 0 }
        for case let fileURL as URL in enumerator {
            total += resolvedFileSize(for: fileURL)
        }
        return total
    }

    func lastUsedDescription(for model: ModelItem) -> String? {
        let lastUsed = UserDefaults.standard.dictionary(forKey: "LocalMgrModelLastUsedDates") as? [String: Double] ?? [:]
        guard let time = lastUsed[model.fileURL.path] else { return nil }
        let date = Date(timeIntervalSince1970: time)
        
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    func usageCount(for model: ModelItem) -> Int {
        let counts = UserDefaults.standard.dictionary(forKey: "LocalMgrModelUsageCounts") as? [String: Int] ?? [:]
        return counts[model.fileURL.path] ?? 0
    }

    func recordModelLaunch(_ model: ModelItem) {
        let path = model.fileURL.path
        let now = Date().timeIntervalSince1970
        
        var lastUsed = UserDefaults.standard.dictionary(forKey: "LocalMgrModelLastUsedDates") as? [String: Double] ?? [:]
        var counts = UserDefaults.standard.dictionary(forKey: "LocalMgrModelUsageCounts") as? [String: Int] ?? [:]
        
        lastUsed[path] = now
        counts[path] = (counts[path] ?? 0) + 1
        
        UserDefaults.standard.set(lastUsed, forKey: "LocalMgrModelLastUsedDates")
        UserDefaults.standard.set(counts, forKey: "LocalMgrModelUsageCounts")
        
        // Notify UI of state changes
        objectWillChange.send()
    }
}
