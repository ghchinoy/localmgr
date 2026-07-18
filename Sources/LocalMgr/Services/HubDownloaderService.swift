import Foundation
import CryptoKit
import Combine

struct CuratedModel: Identifiable {
    let id = UUID()
    let name: String
    let repoID: String
    let filename: String
    let format: ModelFormat
    let sizeBytes: Int64
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
    /// disappearing in the same render pass. Typed as `LocalMgrError` (not
    /// a bare `String`) so `kind` distinguishes e.g. an invalid/expired
    /// token from an unaccepted gated-repo license without the UI having to
    /// parse message text.
    @Published var lastError: LocalMgrError?

    // NOTE (localmgr-3iz): repoID/filename pairs below are verified against
    // the live Hugging Face Hub API (HTTP 200 on the resolve URL) as of
    // 2026-07-16. Google/Meta/Cohere do not publish GGUF quantizations
    // under their own orgs -- use the community quantizer (bartowski) that
    // actually hosts the file, and match its exact filename casing (HF
    // paths are case-sensitive).
    let curatedCatalog: [CuratedModel] = [
        CuratedModel(
            name: "Cohere North Mini Code (30B-A3B Q4_K_M)",
            repoID: "bartowski/North-Mini-Code-1.0-GGUF",
            filename: "North-Mini-Code-1.0-Q4_K_M.gguf",
            format: .gguf,
            sizeBytes: 18_744_024_640,
            sizeFormatted: "18.7 GB",
            expectedSHA256: nil
        ),
        CuratedModel(
            name: "Gemma 2 9B IT (Q4_K_M)",
            repoID: "bartowski/gemma-2-9b-it-GGUF",
            filename: "gemma-2-9b-it-Q4_K_M.gguf",
            format: .gguf,
            sizeBytes: 5_761_057_728,
            sizeFormatted: "5.8 GB",
            expectedSHA256: nil
        ),
        CuratedModel(
            name: "Llama 3.1 8B Instruct (Q4_K_M)",
            repoID: "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF",
            filename: "Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf",
            format: .gguf,
            sizeBytes: 4_920_739_232,
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
            fail(LocalMgrError(
                message: "Couldn't build a download URL for \(repoID)/\(file.path).",
                kind: "invalid-url",
                detail: urlString
            ))
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
            let result = await HFAuth.requestWithFallback(url: url, logCategory: .downloads) { req in
                try await URLSession.shared.download(for: req)
            }

            guard result.statusCode == 200, let tempURL = result.value else {
                if let description = result.transportErrorDescription {
                    self.fail(LocalMgrError(
                        message: "Error downloading \(file.filename): \(description)",
                        kind: "network-transport",
                        detail: description
                    ))
                } else {
                    let statusCode = result.statusCode ?? -1
                    let description = HFAuth.describeError(statusCode: statusCode, repoID: repoID, tokenWasSent: result.tokenWasSent)
                    self.fail(LocalMgrError(
                        message: "Download failed for \(file.filename).",
                        kind: Self.errorKind(forStatusCode: statusCode),
                        detail: "HTTP \(statusCode)",
                        fix: description
                    ))
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
                AppLog.info("Installed \(file.filename) from \(repoID) into \(targetFolder.lastPathComponent)", category: .downloads)
            } catch {
                self.fail(LocalMgrError(
                    message: "Error installing \(file.filename).",
                    kind: "file-io",
                    detail: error.localizedDescription
                ))
            }
        }
    }

    /// Maps an HTTP status code from a failed Hugging Face request to a
    /// stable `LocalMgrError.kind`, so the UI/log can distinguish e.g. an
    /// invalid/expired token from an unaccepted gated-repo license without
    /// parsing message text (see `HFAuth.describeError`, which already
    /// distinguishes 401 vs. 403 in its human-readable copy).
    private static func errorKind(forStatusCode statusCode: Int) -> String {
        switch statusCode {
        case 401: return "auth-invalid-token"
        case 403: return "auth-license-not-accepted"
        case 404: return "not-found"
        default: return "http-error"
        }
    }

    /// Records a download failure. `lastError` persists after `isDownloading`
    /// flips back to false so the UI can surface it (e.g. via an alert)
    /// instead of the in-progress banner disappearing with no explanation.
    private func fail(_ error: LocalMgrError) {
        statusMessage = error.message
        lastError = error
        isDownloading = false
        activeDownloads.removeAll()
        AppLog.error(error.logSummary, category: .downloads)
    }

    func downloadModel(_ model: CuratedModel, targetFolder: URL, catalog: ModelCatalogService) {
        let repoFile = HFRepoFile(path: model.filename, sizeBytes: model.sizeBytes, format: model.format)
        downloadRepoFile(repoID: model.repoID, file: repoFile, targetFolder: targetFolder, catalog: catalog)
    }
}
