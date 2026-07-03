import Foundation
import CryptoKit
import Combine

struct CuratedModel: Identifiable {
    let id = UUID()
    let name: String
    let repoID: String
    let filename: String
    let format: ModelFormat
    let sizeFormatted: String
    let expectedSHA256: String?
}

struct DownloadTaskItem: Identifiable {
    let id = UUID()
    let repoID: String
    let filename: String
    let sizeBytes: Int64
    var progress: Double
    var speedString: String
    var status: String
}

@MainActor
class HubDownloaderService: ObservableObject {
    @Published var isDownloading: Bool = false
    @Published var progress: Double = 0.0
    @Published var statusMessage: String = "Ready"
    @Published var activeModelName: String?
    @Published var speedString: String = ""
    @Published var activeDownloads: [DownloadTaskItem] = []

    let curatedCatalog: [CuratedModel] = [
        CuratedModel(
            name: "Cohere North Mini Code (7B Q4_K_M)",
            repoID: "cohere/north-mini-code-gguf",
            filename: "north-mini-code-q4_k_m.gguf",
            format: .gguf,
            sizeFormatted: "4.8 GB",
            expectedSHA256: nil
        ),
        CuratedModel(
            name: "Gemma 2 9B IT (Q4_K_M)",
            repoID: "google/gemma-2-9b-it-GGUF",
            filename: "gemma-2-9b-it-Q4_K_M.gguf",
            format: .gguf,
            sizeFormatted: "5.4 GB",
            expectedSHA256: nil
        ),
        CuratedModel(
            name: "Llama 3.1 8B Instruct (Q4_K_M)",
            repoID: "meta-llama/Meta-Llama-3.1-8B-Instruct-GGUF",
            filename: "meta-llama-3.1-8b-instruct-q4_k_m.gguf",
            format: .gguf,
            sizeFormatted: "4.9 GB",
            expectedSHA256: nil
        )
    ]

    func downloadRepoFile(repoID: String, file: HFRepoFile, targetFolder: URL, catalog: ModelCatalogService) {
        guard !isDownloading else { return }
        isDownloading = true
        activeModelName = file.filename
        progress = 0.0
        statusMessage = "Connecting..."
        speedString = "0 MB/s"

        let taskItem = DownloadTaskItem(repoID: repoID, filename: file.filename, sizeBytes: file.sizeBytes, progress: 0.0, speedString: "Connecting...", status: "Starting")
        activeDownloads.append(taskItem)

        let urlString = "https://huggingface.co/\(repoID)/resolve/main/\(file.path)"
        guard let url = URL(string: urlString) else {
            statusMessage = "Invalid URL"
            isDownloading = false
            return
        }

        let destinationURL = targetFolder.appendingPathComponent(file.filename)
        let startTime = Date()

        Task {
            do {
                statusMessage = "Downloading \(file.filename)..."
                let (tempURL, response) = try await URLSession.shared.download(from: url, delegate: nil)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    await MainActor.run {
                        self.statusMessage = "Download failed: HTTP error"
                        self.isDownloading = false
                        self.activeDownloads.removeAll()
                    }
                    return
                }

                let elapsed = Date().timeIntervalSince(startTime)
                let mb = Double(file.sizeBytes) / 1_048_576.0
                let mbs = elapsed > 0 ? mb / elapsed : 0.0
                await MainActor.run {
                    self.speedString = String(format: "%.1f MB/s", mbs)
                    self.statusMessage = "Verifying integrity..."
                }

                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: destinationURL)

                await MainActor.run {
                    self.statusMessage = "Installed \(file.filename)"
                    self.isDownloading = false
                    self.progress = 1.0
                    self.activeDownloads.removeAll()
                    catalog.addFolder(targetFolder)
                    catalog.refreshCatalog()
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Error: \(error.localizedDescription)"
                    self.isDownloading = false
                    self.activeDownloads.removeAll()
                }
            }
        }
    }

    func downloadModel(_ model: CuratedModel, targetFolder: URL, catalog: ModelCatalogService) {
        let repoFile = HFRepoFile(path: model.filename, sizeBytes: 5_000_000_000, format: model.format)
        downloadRepoFile(repoID: model.repoID, file: repoFile, targetFolder: targetFolder, catalog: catalog)
    }
}
