import Foundation

/// A single, uniformly-shaped error type used across LocalMgr's failure
/// paths (downloads, gateway proxying, engine launches, etc), modeled on
/// MTPLX's `MTPLXError` (`mtplx/errors.py`).
///
/// Building one `LocalMgrError` instance per failure and routing it to
/// *both* the UI (via `LocalizedError`/`.alert`) and `AppLog` guarantees the
/// message a developer sees in a curl response or a UI banner can never
/// drift from what's recorded in the log/diagnostics bundle -- addressing
/// the class of bug tracked in CHANGELOG v0.4.2 where errors were
/// occasionally swallowed or flashed and disappeared because error state
/// was coupled to a transient progress flag with no single consistent
/// shape.
struct LocalMgrError: Error, Codable, Identifiable, Equatable {
    let id: UUID

    /// Short, user-facing summary of what went wrong (e.g. "Download failed:
    /// your Hugging Face token was rejected as invalid or expired.").
    var message: String

    /// A short, machine-readable/stable category string for this failure
    /// (e.g. `"auth-invalid-token"`, `"auth-license-not-accepted"`,
    /// `"network-transport"`, `"gateway-conflict"`, `"gateway-unavailable"`).
    /// Lets UI/log consumers branch on the failure *kind* rather than
    /// pattern-matching on `message` text.
    var kind: String

    /// Optional additional detail not needed for the headline message (raw
    /// HTTP status code, underlying `localizedDescription`, etc). Must not
    /// contain secrets or full user paths -- same rule as `AppLog` messages
    /// (see `Logging.swift`).
    var detail: String?

    /// A concrete, actionable next step for the user, if one exists (e.g.
    /// "Visit https://huggingface.co/<repo> to accept the model's license,
    /// then retry.").
    var fix: String?

    /// An optional exact command the user could run to resolve the issue.
    var command: String?

    init(
        message: String,
        kind: String,
        detail: String? = nil,
        fix: String? = nil,
        command: String? = nil,
        id: UUID = UUID()
    ) {
        self.id = id
        self.message = message
        self.kind = kind
        self.detail = detail
        self.fix = fix
        self.command = command
    }

    /// Combines `message` and `fix` (if present) into one string suitable
    /// for a single-line banner or alert body.
    var humanSummary: String {
        guard let fix, !fix.isEmpty else { return message }
        return "\(message) \(fix)"
    }

    /// Plain-text rendering suitable for `AppLog`/diagnostics bundle export
    /// (includes `kind`/`detail`, unlike `humanSummary`, which is UI-only).
    var logSummary: String {
        var parts = ["[\(kind)] \(message)"]
        if let detail, !detail.isEmpty { parts.append("detail: \(detail)") }
        if let fix, !fix.isEmpty { parts.append("fix: \(fix)") }
        if let command, !command.isEmpty { parts.append("command: \(command)") }
        return parts.joined(separator: " | ")
    }
}

extension LocalMgrError: LocalizedError {
    var errorDescription: String? { humanSummary }
    var failureReason: String? { detail }
    var recoverySuggestion: String? { fix }
}
