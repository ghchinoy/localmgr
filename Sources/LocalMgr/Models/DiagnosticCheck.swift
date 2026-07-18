import Foundation

/// Severity/outcome of a single `DiagnosticCheck`.
enum DiagnosticStatus: String, Codable, Comparable {
    case pass = "Pass"
    case warn = "Warn"
    case fail = "Fail"

    /// Ordering used by `summarize(_:)` to roll a list of checks into one
    /// overall verdict (worst-of): `.fail` > `.warn` > `.pass`.
    private var severityRank: Int {
        switch self {
        case .pass: return 0
        case .warn: return 1
        case .fail: return 2
        }
    }

    static func < (lhs: DiagnosticStatus, rhs: DiagnosticStatus) -> Bool {
        lhs.severityRank < rhs.severityRank
    }

    var symbolName: String {
        switch self {
        case .pass: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        }
    }
}

/// A single, uniformly-shaped diagnostic result, used across LocalMgr's
/// readiness/health-check surfaces (engine binary presence, port
/// availability, model-file validity, gateway health, etc) instead of ad
/// hoc booleans and badge strings scattered per-subsystem.
///
/// Modeled on MTPLX's `DiagnosticCheck` dataclass (`mtplx/diagnostics.py`):
/// every check states what was observed, what was expected, and (if not
/// passing) a concrete next step -- so any diagnostics surface (an in-app
/// view, a JSON export, a pasteable bug-report bundle) is built from the
/// same underlying data with no risk of the human-facing and
/// machine-facing views drifting apart.
struct DiagnosticCheck: Codable, Identifiable, Equatable {
    /// Stable, human-readable identifier for this check (e.g.
    /// `"engine.llamaCpp.binaryPresent"`), not a random UUID -- lets the
    /// same logical check be recognized/deduplicated across successive
    /// diagnostic runs and referenced from documentation or support
    /// scripts.
    let id: String

    var status: DiagnosticStatus

    /// What was actually observed on this machine (e.g. "not found on PATH
    /// or in known install directories").
    var observed: String

    /// What a passing check would have observed (e.g. "llama-server
    /// discoverable on PATH or in a known install directory").
    var expected: String

    /// A concrete, actionable remediation step. `nil` only for `.pass`
    /// checks, which need no fix.
    var fix: String?

    /// An optional documentation URL with more detail on this check.
    var docsURL: URL?

    /// An optional exact command the user could run to resolve the issue
    /// (e.g. `"brew install llama.cpp"`), suitable for direct display/copy
    /// in the UI.
    var command: String?

    init(
        id: String,
        status: DiagnosticStatus,
        observed: String,
        expected: String,
        fix: String? = nil,
        docsURL: URL? = nil,
        command: String? = nil
    ) {
        self.id = id
        self.status = status
        self.observed = observed
        self.expected = expected
        self.fix = fix
        self.docsURL = docsURL
        self.command = command
    }

    /// Convenience factory for a passing check -- `expected` doubles as
    /// `observed` since, by definition, what was observed matched what was
    /// expected.
    static func pass(id: String, observed: String) -> DiagnosticCheck {
        DiagnosticCheck(id: id, status: .pass, observed: observed, expected: observed)
    }
}

extension Array where Element == DiagnosticCheck {
    /// Rolls a list of checks into one overall verdict: the worst status
    /// present (`.fail` if any check failed, else `.warn` if any warned,
    /// else `.pass`), or `.pass` for an empty list (vacuously nothing is
    /// wrong). Mirrors MTPLX's `summarize_checks()`.
    func summarize() -> DiagnosticStatus {
        self.map(\.status).max() ?? .pass
    }
}
