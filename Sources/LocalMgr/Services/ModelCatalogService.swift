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
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            var existing = UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] ?? []
            existing.append(bookmarkData)
            UserDefaults.standard.set(existing, forKey: bookmarksKey)
            
            _ = url.startAccessingSecurityScopedResource()
            folders.append(url)
            refreshCatalog()
        } catch {
            AppLog.error("Failed to save security-scoped bookmark for folder '\(url.lastPathComponent)': \(error.localizedDescription)", category: .catalog)
        }
    }

    private func loadBookmarkedFolders() {
        guard let bookmarkDataArray = UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] else { return }
        for data in bookmarkDataArray {
            var isStale = false
            do {
                let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
                if url.startAccessingSecurityScopedResource() {
                    folders.append(url)
                }
            } catch {
                AppLog.error("Failed to resolve a saved folder bookmark: \(error.localizedDescription)", category: .catalog)
            }
        }
    }

    func refreshCatalog() {
        var scanned: [ModelItem] = []
        let fileManager = FileManager.default

        for folder in folders {
            guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else { continue }

            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension.lowercased() == "gguf" {
                    let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    let headerInfo = GGUFHeaderParser.inspect(url: fileURL)
                    var item = ModelItem(
                        name: fileURL.deletingPathExtension().lastPathComponent,
                        fileURL: fileURL,
                        format: .gguf,
                        sizeBytes: Int64(size),
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
                } else if ["tflite", "tfl", "task", "litert"].contains(fileURL.pathExtension.lowercased()) {
                    let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    let item = ModelItem(
                        name: fileURL.deletingPathExtension().lastPathComponent,
                        fileURL: fileURL,
                        format: .liteRT,
                        sizeBytes: Int64(size),
                        engineType: .liteRT,
                        quantization: "LiteRT-Quantized",
                        contextLength: 4096,
                        layerCount: 28,
                        headCountKV: 8
                    )
                    scanned.append(item)
                } else if fileURL.lastPathComponent == "config.json" {
                    // Check if parent directory represents an MLX package
                    let parentURL = fileURL.deletingLastPathComponent()
                    let folderName = parentURL.lastPathComponent
                    if folderName.lowercased().contains("mlx") || (try? fileManager.contentsOfDirectory(atPath: parentURL.path).contains(where: { $0.hasSuffix(".safetensors") })) == true {
                        let size = calculateFolderSize(url: parentURL)
                        var item = ModelItem(
                            name: folderName,
                            fileURL: parentURL,
                            format: .mlx,
                            sizeBytes: size,
                            engineType: .mlx,
                            quantization: "MLX-Safetensors",
                            contextLength: 32768,
                            layerCount: 32,
                            headCountKV: 8
                        )
                        let modelType = (try? Data(contentsOf: fileURL))
                            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["model_type"] as? String
                        let compat = ModelCompatibilityClassifier.classifyMLX(modelType: modelType)
                        item.compatibilityTier = compat.tier
                        item.compatibilityMessage = compat.message
                        item.compatibilityRecommendedAction = compat.recommendedAction
                        scanned.append(item)
                    }
                }
            }
        }

        self.models = scanned
    }

    private func calculateFolderSize(url: URL) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
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
