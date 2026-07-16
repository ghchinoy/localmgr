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

/// Shared Hugging Face Hub authentication helper.
///
/// Always probe `HF_TOKEN` and the cached CLI token before hitting any
/// `huggingface.co` endpoint (browsing *or* downloading) so gated/private
/// repositories authenticate consistently across the app.
enum HFAuth {
    static func tokenHeader() -> String? {
        if let envToken = ProcessInfo.processInfo.environment["HF_TOKEN"], !envToken.isEmpty {
            return "Bearer \(envToken)"
        }
        let tokenPath = NSHomeDirectory() + "/.cache/huggingface/token"
        if let cached = try? String(contentsOfFile: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !cached.isEmpty {
            return "Bearer \(cached)"
        }
        return nil
    }

    /// Applies the resolved `Authorization: Bearer <token>` header to a request, if a token is available.
    static func apply(to request: inout URLRequest) {
        if let auth = tokenHeader() {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
    }

    /// Outcome of a request attempted through `requestWithFallback`.
    struct AttemptResult<T: Sendable>: Sendable {
        /// The decoded/downloaded value, only present when `statusCode == 200`.
        let value: T?
        /// The final HTTP status code observed (from whichever attempt was decisive), or `nil` on a transport-level error.
        let statusCode: Int?
        /// Whether an `Authorization` header was sent on the attempt that produced `statusCode`.
        let tokenWasSent: Bool
        /// `localizedDescription` of a transport-level error (DNS, TLS, offline, etc.), if the request never completed.
        let transportErrorDescription: String?
    }

    /// Performs `perform` with the resolved HF token attached (if any). If the
    /// server rejects that with `401`/`403`, retries once **without** the
    /// token: an expired/invalid cached token would otherwise permanently
    /// block repos that are actually public, since HF rejects bad
    /// credentials outright rather than falling back to anonymous access.
    ///
    /// If the unauthenticated retry succeeds, the repo was public all along
    /// and the result is returned as a success. If it also fails, the
    /// fallback's status code is returned (reflecting the repo's true
    /// authentication requirement) with `tokenWasSent = true` so callers can
    /// report that a token was tried and still wasn't sufficient.
    static func requestWithFallback<T: Sendable>(
        url: URL,
        logCategory: LogCategory = .hub,
        perform: @Sendable (URLRequest) async throws -> (T, URLResponse)
    ) async -> AttemptResult<T> {
        let hadToken = tokenHeader() != nil
        var request = URLRequest(url: url)
        apply(to: &request)

        do {
            let (value, response) = try await perform(request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

            guard hadToken, statusCode == 401 || statusCode == 403 else {
                return AttemptResult(value: statusCode == 200 ? value : nil, statusCode: statusCode, tokenWasSent: hadToken, transportErrorDescription: nil)
            }

            // Retry unauthenticated in case the token itself (not the repo) is the problem.
            AppLog.info("HF token rejected (HTTP \(statusCode)) for \(url.host ?? "huggingface.co"); retrying unauthenticated", category: logCategory)
            do {
                let fallbackRequest = URLRequest(url: url)
                let (fallbackValue, fallbackResponse) = try await perform(fallbackRequest)
                let fallbackStatus = (fallbackResponse as? HTTPURLResponse)?.statusCode ?? -1
                if fallbackStatus == 200 {
                    AppLog.info("Unauthenticated retry succeeded; repo is public and the cached token was stale/invalid", category: logCategory)
                    return AttemptResult(value: fallbackValue, statusCode: 200, tokenWasSent: false, transportErrorDescription: nil)
                }
                AppLog.error("Unauthenticated retry also failed (HTTP \(fallbackStatus)) -- repo genuinely requires a valid token", category: logCategory)
                return AttemptResult(value: nil, statusCode: fallbackStatus, tokenWasSent: true, transportErrorDescription: nil)
            } catch {
                // Fallback attempt failed at the transport level; report the original auth rejection instead.
                AppLog.error("Unauthenticated retry failed at the transport level: \(error.localizedDescription)", category: logCategory)
                return AttemptResult(value: nil, statusCode: statusCode, tokenWasSent: true, transportErrorDescription: nil)
            }
        } catch {
            AppLog.error("Request to \(url.host ?? "huggingface.co") failed: \(error.localizedDescription)", category: logCategory)
            return AttemptResult(value: nil, statusCode: nil, tokenWasSent: hadToken, transportErrorDescription: error.localizedDescription)
        }
    }

    /// Builds an actionable message for a non-200 HF response, distinguishing
    /// an invalid/expired token (401) from a valid token lacking access to a
    /// gated repo (403) rather than collapsing both into one generic string.
    static func describeError(statusCode: Int, repoID: String, tokenWasSent: Bool) -> String {
        switch statusCode {
        case 401:
            if tokenWasSent {
                return "Your Hugging Face token was rejected as invalid or expired, and \(repoID) requires authentication. Refresh HF_TOKEN or run `huggingface-cli login` again."
            }
            return "\(repoID) requires Hugging Face authentication. Set HF_TOKEN or run `huggingface-cli login`."
        case 403:
            if tokenWasSent {
                return "Your Hugging Face token doesn't have access to \(repoID). Visit https://huggingface.co/\(repoID) to accept the model's license, then retry."
            }
            return "\(repoID) is gated. Accept the model's license at https://huggingface.co/\(repoID) and set HF_TOKEN, then retry."
        case 404:
            return "\(repoID) or the requested file was not found (HTTP 404)."
        default:
            return "HTTP error (\(statusCode)) from Hugging Face."
        }
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
            AppLog.error("Hub search for '\(query)' failed: \(error.localizedDescription)", category: .hub)
            self.isSearching = false
        }
    }

    func inspectRepoFiles(repoID: String) async {
        isLoadingFiles = true
        repoFiles = []
        errorMessage = nil

        // Try recursive tree first, fallback to /api/models siblings if tree fails or is empty
        let urlStrings = [
            "https://huggingface.co/api/models/\(repoID)/tree/main?recursive=true",
            "https://huggingface.co/api/models/\(repoID)"
        ]

        var extracted: [HFRepoFile] = []
        // Tracks the most informative non-200 outcome across both URL attempts,
        // so a genuine auth/HTTP failure isn't masked by the generic "no files
        // found" message once every variant has been tried.
        var lastFailureStatusCode: Int?
        var lastFailureTokenWasSent = false
        var lastTransportErrorDescription: String?

        for urlString in urlStrings {
            guard let url = URL(string: urlString) else { continue }

            let result = await HFAuth.requestWithFallback(url: url) { req in
                try await URLSession.shared.data(for: req)
            }

            if let data = result.value, result.statusCode == 200 {
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
            } else {
                lastFailureStatusCode = result.statusCode
                lastFailureTokenWasSent = result.tokenWasSent
                lastTransportErrorDescription = result.transportErrorDescription
            }
            if !extracted.isEmpty { break }
        }

        if extracted.isEmpty {
            if let description = lastTransportErrorDescription {
                self.errorMessage = "Couldn't reach Hugging Face: \(description)"
            } else if let statusCode = lastFailureStatusCode, statusCode != 200 {
                self.errorMessage = HFAuth.describeError(statusCode: statusCode, repoID: repoID, tokenWasSent: lastFailureTokenWasSent)
            } else {
                self.errorMessage = "No downloadable model weight files (.gguf, .safetensors, .tflite, .onnx) found in repository tree."
            }
            AppLog.error("Repo inspection failed for \(repoID): \(self.errorMessage ?? "unknown error")", category: .hub)
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
