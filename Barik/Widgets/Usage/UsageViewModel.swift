import SwiftUI

/// Drives usage data for every configured provider. Shared so the bar icon and
/// the popup observe the same state and a refresh updates both at once.
@MainActor
final class UsageViewModel: ObservableObject {
    static let shared = UsageViewModel()

    @Published private(set) var snapshots: [ProviderUsageSnapshot]
    @Published private(set) var isRefreshing = false

    /// The tracked providers/profiles. Add more here (Codex, Gemini, another
    /// Claude profile, …) to surface them alongside Claude.
    let providers: [any UsageProvider]

    private var timer: Timer?
    private let refreshInterval: TimeInterval = 60

    init(providers: [any UsageProvider] = [ClaudeUsageProvider()]) {
        self.providers = providers
        self.snapshots = providers.map {
            .loading(providerId: $0.id, displayName: $0.displayName)
        }
    }

    /// Begins periodic refreshing. Safe to call repeatedly.
    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        let timer = Timer.scheduledTimer(
            withTimeInterval: refreshInterval, repeats: true
        ) { [weak self] _ in
            Task { await self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Re-reads usage for every provider concurrently.
    func refresh() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let providers = self.providers
        var results = [ProviderUsageSnapshot?](
            repeating: nil, count: providers.count)

        await withTaskGroup(of: (Int, ProviderUsageSnapshot).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    (index, await provider.fetchUsage())
                }
            }
            for await (index, snapshot) in group {
                results[index] = snapshot
            }
        }

        snapshots = results.enumerated().map { index, snapshot in
            snapshot
                ?? .loading(
                    providerId: providers[index].id,
                    displayName: providers[index].displayName)
        }
    }
}
