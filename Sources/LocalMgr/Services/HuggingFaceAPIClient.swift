import Foundation
import Combine

struct HFRepoItem: Identifiable, Codable {
    var id: String { _id ?? modelId ?? UUID().uuidString }
    let _id: String?
    let modelId: String?
    let author: String?
    let downloads: Int?
    let likes: Int?

    enum CodingKeys: String, CodingKey {
        case _id
        case modelId
        case author
        case downloads
        case likes
    }
}

struct HFRepoFile: Identifiable {
    let id = UUID()
    let path: String
    let sizeBytes: Int64
    let format: ModelFormat

    var filename: String {
        (path as NSString).lastPathComponent
    }

    var sizeFormatted: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: sizeBytes)
    }
}

@MainActor
class HuggingFaceAPIClient: ObservableObject {
    @Published var searchResults: [HFRepoItem] = []
    @Published var repoFiles: [HFRepoFile] = []
    @Published var isSearching: Bool = false
    @Published var isLoadingFiles: Bool = false
    @Published var errorMessage: String?

    func searchModels(query: String, filterFormat: ModelCatalogService.ModelFilterCategory = .all) async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true
        errorMessage = nil

        var urlString = "https://huggingface.co/api/models?search=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)&sort=downloads&direction=-1&limit=20"
        
        switch filterFormat {
        case .gguf: urlString += "&filter=gguf"
        case .mlx: urlString += "&filter=mlx"
        case .liteRT: urlString += "&filter=tflite"
        case .audio: urlString += "&filter=text-to-speech"
        case .all: break
        }

        guard let url = URL(string: urlString) else {
            isSearching = false
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                errorMessage = "API returned error response"
                isSearching = false
                return
            }

            let items = try JSONDecoder().decode([HFRepoItem].self, from: data)
            self.searchResults = items
            self.isSearching = false
        } catch {
            self.errorMessage = "Search error: \(error.localizedDescription)"
            self.isSearching = false
        }
    }

    func inspectRepoFiles(repoID: String) async {
        isLoadingFiles = true
        repoFiles = []
        errorMessage = nil

        let urlString = "https://huggingface.co/api/models/\(repoID)/tree/main"
        guard let url = URL(string: urlString) else {
            isLoadingFiles = false
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                errorMessage = "Could not inspect files in repository"
                isLoadingFiles = false
                return
            }

            if let jsonList = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                var extracted: [HFRepoFile] = []
                for item in jsonList {
                    guard let path = item["path"] as? String else { continue }
                    let size = item["size"] as? Int64 ?? 0
                    let ext = (path as NSString).pathExtension.lowercased()

                    let format: ModelFormat
                    if ext == "gguf" {
                        format = .gguf
                    } else if ext == "safetensors" {
                        format = .mlx
                    } else if ext == "tflite" || ext == "task" {
                        format = .liteRT
                    } else if ext == "onnx" {
                        format = .onnx
                    } else {
                        continue
                    }

                    extracted.append(HFRepoFile(path: path, sizeBytes: size, format: format))
                }
                self.repoFiles = extracted
            }
            self.isLoadingFiles = false
        } catch {
            self.errorMessage = "Inspection error: \(error.localizedDescription)"
            self.isLoadingFiles = false
        }
    }
}
