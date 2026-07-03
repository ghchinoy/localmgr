import Foundation
import Combine
import AppKit

@MainActor
class ModelCatalogService: ObservableObject {
    @Published var folders: [URL] = []
    @Published var models: [ModelItem] = []
    @Published var selectedModel: ModelItem?
    @Published var searchText: String = ""

    private let bookmarksKey = "LocalMgrFolderBookmarks"

    var filteredModels: [ModelItem] {
        if searchText.isEmpty {
            return models
        }
        return models.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
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
            print("Failed to save bookmark for \(url): \(error)")
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
                print("Failed to resolve bookmark: \(error)")
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
                    let item = ModelItem(
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
                    scanned.append(item)
                } else if fileURL.pathExtension.lowercased() == "tflite" || fileURL.pathExtension.lowercased() == "task" {
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
                        let item = ModelItem(
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
}
