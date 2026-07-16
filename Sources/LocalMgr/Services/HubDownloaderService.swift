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

    /// Persists independently of `isDownloading` so failures remain visible
    /// after the in-progress banner is torn down, instead of flashing and
    /// disappearing in the same render pass.
    @Published var lastError: String?

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
        lastError = nil
        activeModelName = file.filename
        progress = 0.0
        statusMessage = "Connecting..."
        speedString = "0 MB/s"

        let taskItem = DownloadTaskItem(repoID: repoID, filename: file.filename, sizeBytes: file.sizeBytes, progress: 0.0, speedString: "Connecting...", status: "Starting")
        activeDownloads.append(taskItem)

        let urlString = "https://huggingface.co/\(repoID)/resolve/main/\(file.path)"
        guard let url = URL(string: urlString) else {
            fail("Invalid URL for \(repoID)/\(file.path).")
            return
        }

        let destinationURL = targetFolder.appendingPathComponent(file.filename)
        let startTime = Date()

        Task {
            statusMessage = "Downloading \(file.filename)..."

            // Attaches the HF token (env var or cached CLI token) when available.
            // If the server rejects it with 401/403, automatically retries once
            // without the token, since an expired/invalid cached token would
            // otherwise permanently block repos that are actually public.
            let result = await HFAuth.requestWithFallback(url: url) { req in
                try await URLSession.shared.download(for: req)
            }

            guard result.statusCode == 200, let tempURL = result.value else {
                if let description = result.transportErrorDescription {
                    self.fail("Error downloading \(file.filename): \(description)")
                } else {
                    let statusCode = result.statusCode ?? -1
                    self.fail("Download failed: \(HFAuth.describeError(statusCode: statusCode, repoID: repoID, tokenWasSent: result.tokenWasSent))")
                }
                return
            }

            do {
                let elapsed = Date().timeIntervalSince(startTime)
                let mb = Double(file.sizeBytes) / 1_048_576.0
                let mbs = elapsed > 0 ? mb / elapsed : 0.0
                speedString = String(format: "%.1f MB/s", mbs)
                statusMessage = "Verifying integrity..."

                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: destinationURL)

                statusMessage = "Installed \(file.filename)"
                isDownloading = false
                progress = 1.0
                activeDownloads.removeAll()
                catalog.addFolder(targetFolder)
                catalog.refreshCatalog()
            } catch {
                self.fail("Error installing \(file.filename): \(error.localizedDescription)")
            }
        }
    }

    /// Records a download failure. `lastError` persists after `isDownloading`
    /// flips back to false so the UI can surface it (e.g. via an alert)
    /// instead of the in-progress banner disappearing with no explanation.
    private func fail(_ message: String) {
        statusMessage = message
        lastError = message
        isDownloading = false
        activeDownloads.removeAll()
    }

    func downloadModel(_ model: CuratedModel, targetFolder: URL, catalog: ModelCatalogService) {
        let repoFile = HFRepoFile(path: model.filename, sizeBytes: 5_000_000_000, format: model.format)
        downloadRepoFile(repoID: model.repoID, file: repoFile, targetFolder: targetFolder, catalog: catalog)
    }
}
