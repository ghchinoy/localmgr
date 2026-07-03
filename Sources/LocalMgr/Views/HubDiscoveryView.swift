import SwiftUI

struct HubDiscoveryView: View {
    @EnvironmentObject var hfClient: HuggingFaceAPIClient
    @EnvironmentObject var downloader: HubDownloaderService
    @EnvironmentObject var catalog: ModelCatalogService
    @EnvironmentObject var monitor: SystemMonitorService
    @EnvironmentObject var appSettings: AppSettings
    @Environment(\.dismiss) var dismiss

    @State private var searchQuery: String = ""
    @State private var directPasteInput: String = ""
    @State private var selectedRepoID: String?
    @State private var selectedFilter: ModelCatalogService.ModelFilterCategory = .all
    @State private var targetDestinationURL: URL = URL(fileURLWithPath: "/")

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Hugging Face Hub Model Discovery", systemImage: "globe")
                    .font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Search Bar & Direct Paste
            VStack(spacing: 12) {
                HStack {
                    TextField("Search models (e.g. 'gemma 2', 'llama 3', 'kokoro')...", text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            Task { await hfClient.searchModels(query: searchQuery, filterFormat: selectedFilter) }
                        }
                    Button("Search") {
                        Task { await hfClient.searchModels(query: searchQuery, filterFormat: selectedFilter) }
                    }
                    .buttonStyle(.borderedProminent)
                }

                HStack {
                    Text("Or paste Repo ID / URL:")
                        .font(.caption)
                    TextField("e.g. bartowski/Llama-3.2-8B-Instruct-GGUF", text: $directPasteInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { inspectDirectInput() }
                    Button("Inspect Repo") { inspectDirectInput() }
                        .buttonStyle(.bordered)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.05))

            // Format Filter Pills
            Picker("Format", selection: $selectedFilter) {
                ForEach(ModelCatalogService.ModelFilterCategory.allCases) { cat in
                    Text(cat.rawValue).tag(cat)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .onChange(of: selectedFilter) {
                if !searchQuery.isEmpty {
                    Task { await hfClient.searchModels(query: searchQuery, filterFormat: selectedFilter) }
                }
            }

            Divider()

            // Main Split: Repos List on Left, Files on Right
            HStack(spacing: 0) {
                // Repos Column
                List(selection: $selectedRepoID) {
                    if hfClient.isSearching {
                        ProgressView("Searching Hub...")
                            .frame(maxWidth: .infinity)
                    } else if hfClient.searchResults.isEmpty && selectedRepoID == nil {
                        Text("Search or inspect a repository above.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(hfClient.searchResults) { repo in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(repo.id)
                                    .font(.headline)
                                HStack {
                                    Text("⬇ \(repo.downloads ?? 0)")
                                    Text("♥ \(repo.likes ?? 0)")
                                }
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                            .tag(repo.id)
                        }
                    }
                }
                .frame(width: 280)
                .onChange(of: selectedRepoID) { oldValue, newRepo in
                    if let repo = newRepo {
                        Task { await hfClient.inspectRepoFiles(repoID: repo) }
                    }
                }

                Divider()

                // Files Column
                VStack(alignment: .leading, spacing: 0) {
                    if let repoID = selectedRepoID {
                        HStack {
                            Text("Files in \(repoID)")
                                .font(.headline)
                            Spacer()
                        }
                        .padding()
                        .background(Color(NSColor.controlBackgroundColor))

                        Divider()

                        if hfClient.isLoadingFiles {
                            ProgressView("Inspecting weight files...")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if hfClient.repoFiles.isEmpty {
                            Text("No compatible weight files found (.gguf, .safetensors, .tflite, .onnx).")
                                .foregroundColor(.secondary)
                                .padding()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            List {
                                ForEach(hfClient.repoFiles) { file in
                                    let fits = file.sizeBytes < (monitor.freeRAMBytes + 2_000_000_000)
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(file.filename)
                                                .font(.subheadline.bold())
                                            HStack {
                                                Text(file.format.rawValue)
                                                    .font(.caption2)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.secondary.opacity(0.15))
                                                    .cornerRadius(4)
                                                Text(file.sizeFormatted)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)

                                                Text(fits ? "🟢 Fits Comfortably" : "🔴 Exceeds RAM (Will Thrash)")
                                                    .font(.caption2.bold())
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(fits ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                                                    .foregroundColor(fits ? .green : .red)
                                                    .cornerRadius(4)
                                            }
                                        }
                                        Spacer()
                                        Button("Download") {
                                            downloader.downloadRepoFile(repoID: repoID, file: file, targetFolder: targetDestinationURL, catalog: catalog)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(downloader.isDownloading)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "folder.badge.questionmark")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text("Select a repository on the left to view downloadable weights and RAM fit predictions.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }

            Divider()

            // Footer: Destination Selector & Background Indicator
            HStack {
                Text("Save to Vault:")
                    .font(.caption)
                Picker("", selection: $targetDestinationURL) {
                    Text("Default Storage (\(appSettings.resolvedDownloadURL.lastPathComponent))").tag(appSettings.resolvedDownloadURL)
                    ForEach(catalog.folders, id: \.self) { folder in
                        Text(folder.path).tag(folder)
                    }
                }
                .frame(width: 300)

                Spacer()

                if downloader.isDownloading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("\(downloader.statusMessage) (\(downloader.speedString))")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 880, height: 620)
        .onAppear {
            targetDestinationURL = appSettings.resolvedDownloadURL
            if !catalog.folders.contains(appSettings.resolvedDownloadURL) {
                catalog.addFolder(appSettings.resolvedDownloadURL)
            }
        }
    }

    private func inspectDirectInput() {
        let clean = directPasteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var repo = clean
        if repo.hasPrefix("https://huggingface.co/") {
            repo = repo.replacingOccurrences(of: "https://huggingface.co/", with: "")
            if let slashIndex = repo.firstIndex(of: "/") {
                let nextSlash = repo[repo.index(after: slashIndex)...].firstIndex(of: "/") ?? repo.endIndex
                repo = String(repo[..<nextSlash])
            }
        }
        selectedRepoID = repo
        Task { await hfClient.inspectRepoFiles(repoID: repo) }
    }
}
