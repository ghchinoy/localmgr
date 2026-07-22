import Foundation
import Combine

struct TelemetryRecord: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var timestamp: Date
    var modelName: String
    var engine: String
    var ttftMs: Double
    var tps: Double
    var promptTokens: Int
    var completionTokens: Int
    var cachedTokens: Int
    var thermalState: String
}

struct ModelTelemetrySummary: Identifiable {
    var id: String { modelName }
    var modelName: String
    var totalRequests: Int
    var totalTokens: Int
    var avgTTFT: Double
    var avgTPS: Double
    var avgKVHitRate: Double
}

@MainActor
class TelemetryStore: ObservableObject {
    @Published var records: [TelemetryRecord] = []
    @Published var modelSummaries: [String: ModelTelemetrySummary] = [:]

    private let fileManager = FileManager.default
    private var storageURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("LocalMgr/Telemetry", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.jsonl")
    }

    init() {
        loadHistory()
    }

    func record(modelName: String, engine: String, ttftMs: Double, durationMs: Double, promptTokens: Int, completionTokens: Int, cachedTokens: Int, thermalState: String) {
        let tps = (durationMs > 0 && completionTokens > 0) ? (Double(completionTokens) / (durationMs / 1000.0)) : 0.0
        let rec = TelemetryRecord(
            timestamp: Date(),
            modelName: modelName,
            engine: engine,
            ttftMs: ttftMs,
            tps: tps,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cachedTokens: cachedTokens,
            thermalState: thermalState
        )
        records.append(rec)
        recomputeSummaries()
        appendToFile(rec)
    }

    func clearHistory() {
        records.removeAll()
        modelSummaries.removeAll()
        try? fileManager.removeItem(at: storageURL)
    }

    private func recomputeSummaries() {
        var dict: [String: [TelemetryRecord]] = [:]
        for rec in records {
            dict[rec.modelName, default: []].append(rec)
        }

        var newSummaries: [String: ModelTelemetrySummary] = [:]
        for (name, recs) in dict {
            let totalReqs = recs.count
            let totalToks = recs.reduce(0) { $0 + $1.promptTokens + $1.completionTokens }
            let validTTFT = recs.filter { $0.ttftMs > 0 }
            let avgTTFT = validTTFT.isEmpty ? 0.0 : validTTFT.reduce(0.0) { $0 + $1.ttftMs } / Double(validTTFT.count)
            let validTPS = recs.filter { $0.tps > 0 }
            let avgTPS = validTPS.isEmpty ? 0.0 : validTPS.reduce(0.0) { $0 + $1.tps } / Double(validTPS.count)
            
            let totalPrompt = recs.reduce(0) { $0 + max(1, $1.promptTokens) }
            let totalCached = recs.reduce(0) { $0 + $1.cachedTokens }
            let avgKV = Double(totalCached) / Double(totalPrompt) * 100.0

            newSummaries[name] = ModelTelemetrySummary(
                modelName: name,
                totalRequests: totalReqs,
                totalTokens: totalToks,
                avgTTFT: avgTTFT,
                avgTPS: avgTPS,
                avgKVHitRate: avgKV
            )
        }
        modelSummaries = newSummaries
    }

    private func loadHistory() {
        guard fileManager.fileExists(atPath: storageURL.path),
              let content = try? String(contentsOf: storageURL, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let decoder = JSONDecoder()
        var loaded: [TelemetryRecord] = []
        for line in lines {
            if let data = line.data(using: .utf8), let rec = try? decoder.decode(TelemetryRecord.self, from: data) {
                loaded.append(rec)
            }
        }
        self.records = loaded
        recomputeSummaries()
    }

    private func appendToFile(_ rec: TelemetryRecord) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(rec), let str = String(data: data, encoding: .utf8) else { return }
        let line = str + "\n"
        if fileManager.fileExists(atPath: storageURL.path), let handle = try? FileHandle(forWritingTo: storageURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: storageURL, atomically: true, encoding: .utf8)
        }
    }
}
