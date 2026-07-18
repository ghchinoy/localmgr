import Foundation
import Darwin

/// macOS's own kernel memory-pressure classification, read directly via
/// `sysctlbyname("kern.memorystatus_vm_pressure_level")`. This is a finer
/// signal than `DispatchSource.makeMemoryPressureSource`'s `.warning`/
/// `.critical` event mask alone -- it lets us poll the *current* level on
/// our own cadence rather than only reacting to edge-triggered kernel
/// notifications, which is what enables the hysteresis policy below.
enum KernelMemoryPressureLevel: Int32 {
    case normal = 1
    case warning = 2
    case critical = 4

    /// Reads the current kernel-reported pressure level. Returns `.normal`
    /// if the sysctl is unavailable for any reason (never throws/crashes --
    /// a monitoring signal must fail safe, not fail loud).
    static func current() -> KernelMemoryPressureLevel {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0)
        guard result == 0, let level = KernelMemoryPressureLevel(rawValue: value) else {
            return .normal
        }
        return level
    }
}

/// The action `MemoryPressureGuard` recommends in response to an observed
/// pressure transition. Deliberately does not perform eviction itself --
/// callers (e.g. `SystemMonitorService`) decide *how* to satisfy `.softEvict`/
/// `.hardEvict` (which runner to stop, whether one is actively serving a
/// request, etc).
enum MemoryPressureAction: Equatable {
    /// No action required -- either pressure is normal, or we're within a
    /// cooldown/defer window and choosing not to re-act yet.
    case none
    /// Pressure rose to `.warning`. Non-urgent: safe to defer briefly if a
    /// request is in flight.
    case softEvict
    /// Pressure rose to `.critical`. Must act immediately regardless of any
    /// in-flight request.
    case hardEvict
}

/// A pure, dependency-free decision core implementing edge-triggered
/// hysteresis over `KernelMemoryPressureLevel`.
///
/// Modeled on MTPLX's `_MemoryPressureGuard` (mtplx/server/openai.py):
/// rather than acting on every poll while pressure remains elevated (which
/// itself burns CPU/thrashes reclaiming caches repeatedly), this only acts
/// on the **rising edge** into `.warning`/`.critical`, re-arms after a
/// cooldown window while pressure stays elevated, and lets `.warning`-level
/// action be deferred briefly if the caller reports an in-flight request --
/// `.critical` always acts immediately regardless.
///
/// No Foundation/SwiftUI/Combine dependency beyond `Foundation` for `Date`/
/// `TimeInterval`, and the level reader is injectable, so this type is
/// trivially unit-testable with synthetic pressure-level sequences and a
/// fake clock (see `localmgr-jhj.1`/`.3` once the test target exists).
struct MemoryPressureGuard {
    /// How long to wait before allowing another action while pressure
    /// remains continuously elevated (matches MTPLX's ~120s re-arm window).
    var rearmCooldown: TimeInterval = 120.0

    /// How long a `.warning`-level (non-critical) action may be deferred if
    /// the caller reports work in flight, so a soft eviction doesn't tank an
    /// active generation. `.critical` ignores this entirely.
    var warningDeferWindow: TimeInterval = 60.0

    /// Reads the current kernel pressure level. Injectable so tests can
    /// supply a scripted sequence instead of hitting the real sysctl.
    var readLevel: () -> KernelMemoryPressureLevel = { KernelMemoryPressureLevel.current() }

    /// Returns the current wall-clock time. Injectable for deterministic
    /// tests.
    var now: () -> Date = { Date() }

    private(set) var lastLevel: KernelMemoryPressureLevel = .normal
    private(set) var lastActionDate: Date?
    private var deferredWarningSince: Date?

    /// Explicit memberwise-style initializer. Required because the private
    /// stored properties above (`lastLevel`, `lastActionDate`,
    /// `deferredWarningSince`) suppress Swift's automatic memberwise
    /// initializer synthesis for the whole struct -- without this,
    /// `MemoryPressureGuard(rearmCooldown:..., readLevel:..., now:...)`
    /// would fail to compile, silently forcing every caller (including
    /// tests) back to the zero-argument default and post-init mutation.
    init(
        rearmCooldown: TimeInterval = 120.0,
        warningDeferWindow: TimeInterval = 60.0,
        readLevel: @escaping () -> KernelMemoryPressureLevel = { KernelMemoryPressureLevel.current() },
        now: @escaping () -> Date = { Date() }
    ) {
        self.rearmCooldown = rearmCooldown
        self.warningDeferWindow = warningDeferWindow
        self.readLevel = readLevel
        self.now = now
    }

    /// Evaluate one polling tick and return the recommended action.
    ///
    /// - Parameter requestInFlight: Whether a model runner is actively
    ///   serving a request right now. Only affects `.warning`-level
    ///   deferral; `.critical` always acts.
    mutating func evaluate(requestInFlight: Bool = false) -> MemoryPressureAction {
        let level = readLevel()
        let currentDate = now()
        let risingEdge = level.rawValue > lastLevel.rawValue
        lastLevel = level

        switch level {
        case .normal:
            deferredWarningSince = nil
            return .none

        case .critical:
            // Critical always acts immediately, whether it's a fresh rising
            // edge or we're still elevated past the cooldown window.
            if risingEdge || readyToReArm(at: currentDate) {
                deferredWarningSince = nil
                lastActionDate = currentDate
                return .hardEvict
            }
            return .none

        case .warning:
            guard risingEdge || readyToReArm(at: currentDate) else {
                return .none
            }
            if requestInFlight {
                // Defer, but only up to warningDeferWindow -- after that,
                // act anyway even mid-request rather than let pressure ride
                // indefinitely.
                if deferredWarningSince == nil {
                    deferredWarningSince = currentDate
                }
                if let deferredSince = deferredWarningSince,
                   currentDate.timeIntervalSince(deferredSince) < warningDeferWindow {
                    return .none
                }
            }
            deferredWarningSince = nil
            lastActionDate = currentDate
            return .softEvict
        }
    }

    private func readyToReArm(at date: Date) -> Bool {
        guard let last = lastActionDate else { return true }
        return date.timeIntervalSince(last) >= rearmCooldown
    }
}
