import Foundation
import os

/// Broad functional area a log entry belongs to. Mirrors the app's service
/// boundaries so entries can be filtered meaningfully in the in-app
/// Diagnostics view and in Console.app / `log stream --predicate
/// 'category == "Downloads"'`.
enum LogCategory: String, CaseIterable, Identifiable, Sendable {
    case general = "General"
    case downloads = "Downloads"
    case hub = "HuggingFaceHub"
    case gateway = "Gateway"
    case runner = "Runner"
    case catalog = "Catalog"

    var id: String { rawValue }
}

enum LogLevel: String, Sendable {
    case debug = "Debug"
    case info = "Info"
    case error = "Error"
    case fault = "Fault"

    var symbolName: String {
        switch self {
        case .debug: return "ladybug"
        case .info: return "info.circle"
        case .error: return "exclamationmark.triangle"
        case .fault: return "xmark.octagon"
        }
    }
}

/// A single application-level diagnostic entry, mirrored from an `os.Logger`
/// emission into an in-memory ring buffer so it can be displayed live in the
/// in-app Diagnostics view. This is distinct from the model-runner "Live
/// Logs" tab in `ModelInspectorView`, which only captures spawned engine
/// subprocess (`llama-server`, `mlx_lm.server`, etc.) stdout/stderr.
struct AppLogEntry: Identifiable, Equatable, Sendable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let category: LogCategory
    let message: String
}

/// In-memory ring buffer of recent `AppLog` emissions, powering the in-app
/// Diagnostics view (`DiagnosticsView`). Capped at `maxEntries` so
/// long-running sessions don't grow this unbounded -- the full history
/// always remains queryable separately via Console.app / `log show` since
/// every entry is also emitted through `os.Logger`.
@MainActor
final class AppDiagnostics: ObservableObject {
    static let shared = AppDiagnostics()

    @Published private(set) var entries: [AppLogEntry] = []

    private let maxEntries = 500

    private init() {}

    func append(_ entry: AppLogEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }
}

/// The unified-logging subsystem identifier for LocalMgr, matching
/// `CFBundleIdentifier` in Info.plist so entries are easy to find in
/// Console.app (filter by subsystem) or via:
///   log show --predicate 'subsystem == "com.localmgr.mac"' --last 1h
private let appLogSubsystem = "com.localmgr.mac"

private let categoryLoggers: [LogCategory: Logger] = Dictionary(
    uniqueKeysWithValues: LogCategory.allCases.map { category in
        (category, Logger(subsystem: appLogSubsystem, category: category.rawValue))
    }
)

/// Single entry point for application-level diagnostic logging.
///
/// Every call both:
///  1. Emits through Apple's unified logging system via `os.Logger`, so
///     entries are inspectable in Console.app / `log stream` even after the
///     app has quit or a user never opens the in-app Diagnostics view, and
///  2. Mirrors into `AppDiagnostics.shared` for live, in-app display.
///
/// This is intentionally separate from `BackendRunnerManager.logOutput`,
/// which only captures spawned model-engine subprocess stdout/stderr, not
/// app-internal events (network failures, process launch errors, gateway
/// bind failures, etc).
///
/// Callers must not interpolate secrets (HF tokens, full user file paths)
/// into `message` -- prefer booleans/counts ("token present: true") or
/// last-path-components over raw values.
enum AppLog {
    static func debug(_ message: String, category: LogCategory = .general) {
        emit(.debug, category: category, message: message)
    }

    static func info(_ message: String, category: LogCategory = .general) {
        emit(.info, category: category, message: message)
    }

    static func error(_ message: String, category: LogCategory = .general) {
        emit(.error, category: category, message: message)
    }

    static func fault(_ message: String, category: LogCategory = .general) {
        emit(.fault, category: category, message: message)
    }

    private static func emit(_ level: LogLevel, category: LogCategory, message: String) {
        let logger = categoryLoggers[category] ?? Logger(subsystem: appLogSubsystem, category: category.rawValue)
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        case .fault: logger.fault("\(message, privacy: .public)")
        }

        let entry = AppLogEntry(timestamp: Date(), level: level, category: category, message: message)
        Task { @MainActor in
            AppDiagnostics.shared.append(entry)
        }
    }
}
