import Foundation
import Combine

struct SemanticVersionComparator {
    static func isOutdated(installed: String, latest: String) -> Bool {
        // Strip non-digits and non-dots from versions for raw semver comparisons
        let cleanInstalled = installed.trimmingCharacters(in: CharacterSet.decimalDigits.inverted.subtracting(CharacterSet(charactersIn: ".")))
        let cleanLatest = latest.trimmingCharacters(in: CharacterSet.decimalDigits.inverted.subtracting(CharacterSet(charactersIn: ".")))
        
        // If they are integers (like llama.cpp release bXXXX vs XXXX), do integer comparison
        if let i1 = Int(cleanInstalled), let i2 = Int(cleanLatest) {
            return i1 < i2
        }
        
        // Otherwise, do standard semver parts comparison
        let v1 = cleanInstalled.components(separatedBy: ".").compactMap { Int($0) }
        let v2 = cleanLatest.components(separatedBy: ".").compactMap { Int($0) }
        
        for i in 0..<max(v1.count, v2.count) {
            let p1 = i < v1.count ? v1[i] : 0
            let p2 = i < v2.count ? v2[i] : 0
            if p1 < p2 {
                return true
            } else if p1 > p2 {
                return false
            }
        }
        return false
    }
}

@MainActor
class UpstreamEngineVersionService: ObservableObject {
    @Published var latestVersions: [EngineType: String] = [:]
    @Published var isChecking: Bool = false

    private let cacheKey = "LocalMgrUpstreamVersionCache"
    private let cacheTimeKey = "LocalMgrUpstreamVersionCacheTime"

    func checkLatestVersions(force: Bool = false) async {
        guard !isChecking else { return }
        
        let now = Date().timeIntervalSince1970
        let lastCheck = UserDefaults.standard.double(forKey: cacheTimeKey)
        
        // Use cached versions if checked within last 24 hours and not forced
        if !force && (now - lastCheck) < 86400,
           let cached = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String] {
            var loaded: [EngineType: String] = [:]
            for (key, val) in cached {
                if let type = EngineType(rawValue: key) {
                    loaded[type] = val
                }
            }
            if !loaded.isEmpty {
                self.latestVersions = loaded
                return
            }
        }
        
        isChecking = true
        
        // Fetch in parallel
        async let latestLlama = fetchLlamaVersion()
        async let latestMlx = fetchPyPIVersion(packageName: "mlx-lm")
        async let latestLiteRT = fetchPyPIVersion(packageName: "litert-lm")
        
        let llama = await latestLlama
        let mlx = await latestMlx
        let litert = await latestLiteRT
        
        var cached: [String: String] = [:]
        var loaded: [EngineType: String] = [:]
        
        if let l = llama {
            loaded[.llamaCpp] = l
            cached[EngineType.llamaCpp.rawValue] = l
        }
        if let m = mlx {
            loaded[.mlx] = m
            cached[EngineType.mlx.rawValue] = m
        }
        if let lr = litert {
            loaded[.liteRT] = lr
            cached[EngineType.liteRT.rawValue] = lr
        }
        
        self.latestVersions = loaded
        UserDefaults.standard.set(cached, forKey: cacheKey)
        UserDefaults.standard.set(now, forKey: cacheTimeKey)
        
        isChecking = false
    }

    private func fetchLlamaVersion() async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/ggerganov/llama.cpp/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("LocalMgr", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 5.0
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tagName = json["tag_name"] as? String {
                // Strip leading 'b' if present, e.g. "b9840" -> "9840"
                if tagName.hasPrefix("b") {
                    return String(tagName.dropFirst())
                }
                return tagName
            }
        } catch {
            AppLog.error("Failed to fetch latest llama.cpp version from GitHub: \(error.localizedDescription)", category: .gateway)
        }
        return nil
    }

    private func fetchPyPIVersion(packageName: String) async -> String? {
        guard let url = URL(string: "https://pypi.org/pypi/\(packageName)/json") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("LocalMgr", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 5.0
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let info = json["info"] as? [String: Any],
               let version = info["version"] as? String {
                return version
            }
        } catch {
            AppLog.error("Failed to fetch latest \(packageName) version from PyPI: \(error.localizedDescription)", category: .gateway)
        }
        return nil
    }
}

struct LocalEngineVersionProber {
    static func probeLlamaCpp(resolvedPath: String) async -> String? {
        let output = await runCommand(executable: resolvedPath, arguments: ["--version"])
        // Output format: "version: 9840 (8c146a836)" or similar.
        if let line = output.components(separatedBy: .newlines).first(where: { $0.contains("version:") }) {
            let parts = line.components(separatedBy: "version:")
            if parts.count > 1 {
                let ver = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                // Extract just the build integer if possible, e.g., "9840 (8c146a836)" -> "9840"
                if let build = ver.components(separatedBy: " ").first {
                    return build
                }
                return ver
            }
        }
        return nil
    }

    static func probeMLX(resolvedPath: String) async -> String? {
        let mlxPath = resolvedPath.replacingOccurrences(of: "mlx_lm.server", with: "mlx_lm")
        if FileManager.default.fileExists(atPath: mlxPath) {
            let output = await runCommand(executable: mlxPath, arguments: ["--version"])
            let clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty && clean.count < 15 { return clean }
        }
        // Fallback to python
        let pythonPath = resolvedPath.replacingOccurrences(of: "mlx_lm.server", with: "python")
        if FileManager.default.fileExists(atPath: pythonPath) {
            let output = await runCommand(executable: pythonPath, arguments: ["-c", "import importlib.metadata; print(importlib.metadata.version('mlx-lm'))"])
            let clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { return clean }
        }
        return nil
    }

    static func probeLiteRT(resolvedPath: String) async -> String? {
        let output = await runCommand(executable: resolvedPath, arguments: ["--version"])
        let clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.contains("version") {
            if let range = clean.range(of: "version ") {
                return String(clean[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if !clean.isEmpty && clean.count < 15 { return clean }
        
        // Fallback to python
        let pythonPath = resolvedPath.replacingOccurrences(of: "litert-lm", with: "python").replacingOccurrences(of: "litert-benchmark", with: "python")
        if FileManager.default.fileExists(atPath: pythonPath) {
            let output = await runCommand(executable: pythonPath, arguments: ["-c", "import importlib.metadata; print(importlib.metadata.version('litert-lm'))"])
            let clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { return clean }
        }
        return nil
    }

    private static func runCommand(executable: String, arguments: [String]) async -> String {
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8) ?? ""
            } catch {
                return ""
            }
        }.value
    }
}
