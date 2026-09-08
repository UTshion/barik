import SwiftUI

/// A single rate-limit window (e.g. Claude's 5-hour session or 7-day weekly).
struct UsageWindow: Identifiable {
    /// Stable identity within a provider snapshot (the limit "kind").
    let id: String
    /// Human-readable label, e.g. "5-hour", "Weekly", "Weekly · Fable".
    let title: String
    /// Percentage of the window consumed, 0–100.
    let usedPercent: Double
    /// When the window resets, if known.
    let resetsAt: Date?

    /// Whether usage has crossed the warning threshold (mirrors orca's 80%).
    var isWarning: Bool { usedPercent >= 80 }

    /// Tint reflecting how close the window is to its limit.
    var tint: Color {
        if usedPercent >= 95 { return .red }
        if usedPercent >= 80 { return .orange }
        return .green
    }
}

/// The result of querying one provider (optionally one profile of it).
struct ProviderUsageSnapshot: Identifiable {
    let providerId: String
    let displayName: String
    var account: String?
    var windows: [UsageWindow]
    var status: UsageStatus
    var updatedAt: Date?

    var id: String { providerId }

    /// The tightest window, used to summarize the provider at a glance.
    var tightestWindow: UsageWindow? {
        windows.max { $0.usedPercent < $1.usedPercent }
    }

    static func loading(providerId: String, displayName: String)
        -> ProviderUsageSnapshot
    {
        ProviderUsageSnapshot(
            providerId: providerId, displayName: displayName, account: nil,
            windows: [], status: .loading, updatedAt: nil)
    }
}

enum UsageStatus: Equatable {
    case loading
    case ok
    case notSignedIn
    case error(String)

    var message: String? {
        switch self {
        case .loading: return "Loading usage…"
        case .ok: return nil
        case .notSignedIn: return "Not signed in"
        case .error(let message): return message
        }
    }
}

/// A source of usage/rate-limit data. Implement one per provider (Claude,
/// Codex, Gemini, …) or per profile to support switching between them.
protocol UsageProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// Fetches a fresh snapshot. Runs off the main actor.
    func fetchUsage() async -> ProviderUsageSnapshot
}
