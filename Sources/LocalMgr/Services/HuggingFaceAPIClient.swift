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

        var tokenHeader: String? = nil
        if let envToken = ProcessInfo.processInfo.environment["HF_TOKEN"], !envToken.isEmpty {
            tokenHeader = "Bearer \(envToken)"
        } else {
            let tokenPath = NSHomeDirectory() + "/.cache/huggingface/token"
            if let cached = try? String(contentsOfFile: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !cached.isEmpty {
                tokenHeader = "Bearer \(cached)"
            }
        }

        // Try recursive tree first, fallback to /api/models siblings if tree fails or is empty
        let urlStrings = [
            "https://huggingface.co/api/models/\(repoID)/tree/main?recursive=true",
            "https://huggingface.co/api/models/\(repoID)"
        ]

        var extracted: [HFRepoFile] = []

        for urlString in urlStrings {
            guard let url = URL(string: urlString) else { continue }
            var req = URLRequest(url: url)
            if let auth = tokenHeader { req.setValue(auth, forHTTPHeaderField: "Authorization") }

            if let (data, response) = try? await URLSession.shared.data(for: req),
               let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                
                if let jsonList = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    for item in jsonList {
                        guard let path = item["path"] as? String else { continue }
                        let size = item["size"] as? Int64 ?? 0
                        if let file = parseHFRepoFile(path: path, size: size) {
                            extracted.append(file)
                        }
                    }
                } else if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let siblings = dict["siblings"] as? [[String: Any]] {
                    for item in siblings {
                        guard let path = item["rfilename"] as? String else { continue }
                        let size = item["size"] as? Int64 ?? 0
                        if let file = parseHFRepoFile(path: path, size: size) {
                            extracted.append(file)
                        }
                    }
                }
            }
            if !extracted.isEmpty { break }
        }

        if extracted.isEmpty {
            self.errorMessage = "No downloadable model weight files (.gguf, .safetensors, .tflite, .onnx) found in repository tree."
        } else {
            self.repoFiles = extracted
        }
        self.isLoadingFiles = false
    }

    private func parseHFRepoFile(path: String, size: Int64) -> HFRepoFile? {
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
            return nil
        }
        return HFRepoFile(path: path, sizeBytes: size, format: format)
    }
}
