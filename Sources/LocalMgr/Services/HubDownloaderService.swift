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

@MainActor
class HubDownloaderService: ObservableObject {
    @Published var isDownloading: Bool = false
    @Published var progress: Double = 0.0
    @Published var statusMessage: String = "Ready"
    @Published var activeModelName: String?

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

    private var downloadTask: URLSessionDownloadTask?

    func downloadModel(_ model: CuratedModel, targetFolder: URL, catalog: ModelCatalogService) {
        guard !isDownloading else { return }
        isDownloading = true
        activeModelName = model.name
        progress = 0.0
        statusMessage = "Connecting to Hugging Face Hub..."

        let urlString = "https://huggingface.co/\(model.repoID)/resolve/main/\(model.filename)"
        guard let url = URL(string: urlString) else {
            statusMessage = "Error: Invalid Hugging Face URL"
            isDownloading = false
            return
        }

        let destinationURL = targetFolder.appendingPathComponent(model.filename)

        Task {
            do {
                statusMessage = "Downloading \(model.filename)..."
                let (tempURL, response) = try await URLSession.shared.download(from: url, delegate: nil)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    await MainActor.run {
                        self.statusMessage = "Download failed: HTTP error"
                        self.isDownloading = false
                    }
                    return
                }

                await MainActor.run { self.statusMessage = "Verifying SHA-256 hash integrity..." }
                
                if let expectedSHA = model.expectedSHA256 {
                    let isValid = try verifySHA256(fileURL: tempURL, expectedHash: expectedSHA)
                    if !isValid {
                        try? FileManager.default.removeItem(at: tempURL)
                        await MainActor.run {
                            self.statusMessage = "Security Alert: SHA-256 checksum mismatch! Download discarded."
                            self.isDownloading = false
                        }
                        return
                    }
                }

                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: destinationURL)

                await MainActor.run {
                    self.statusMessage = "Successfully verified and installed \(model.filename)"
                    self.isDownloading = false
                    self.progress = 1.0
                    catalog.refreshCatalog()
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Download error: \(error.localizedDescription)"
                    self.isDownloading = false
                }
            }
        }
    }

    nonisolated private func verifySHA256(fileURL: URL, expectedHash: String) throws -> Bool {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        while let chunk = try? fileHandle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize()
        let computedHash = digest.map { String(format: "%02x", $0) }.joined()
        return computedHash.lowercased() == expectedHash.lowercased()
    }
}
