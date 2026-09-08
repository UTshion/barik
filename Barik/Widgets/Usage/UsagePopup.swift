import SwiftUI

/// Detailed usage popover: one section per provider, each listing its usage
/// windows with progress bars and reset times. Includes a manual refresh.
struct UsagePopup: View {
    @ObservedObject private var viewModel = UsageViewModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            ForEach(Array(viewModel.snapshots.enumerated()), id: \.element.id) {
                index, snapshot in
                if index > 0 {
                    Divider().overlay(Color.white.opacity(0.12))
                }
                providerSection(snapshot)
            }
        }
        .padding(22)
        .frame(width: 320)
        .background(Color.black)
        .onAppear {
            Task { await viewModel.refresh() }
        }
    }

    private var header: some View {
        HStack {
            Text("Usage")
                .font(.title3.bold())
                .foregroundStyle(.white)
            Spacer()
            Button {
                Task { await viewModel.refresh() }
            } label: {
                if viewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isRefreshing)
            .help("Refresh usage")
        }
    }

    @ViewBuilder
    private func providerSection(_ snapshot: ProviderUsageSnapshot) -> some View
    {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                UsageProviderIcon(providerId: snapshot.providerId, size: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.displayName)
                        .font(.headline)
                        .foregroundStyle(.white)
                    if let account = snapshot.account {
                        Text(account)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                Spacer()
                if let updated = snapshot.updatedAt {
                    Text(updated, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            switch snapshot.status {
            case .ok:
                if snapshot.windows.isEmpty {
                    statusText("No usage data")
                } else {
                    ForEach(snapshot.windows) { window in
                        windowRow(window)
                    }
                }
            case .loading:
                statusText("Loading usage…")
            case .notSignedIn:
                statusText("Not signed in")
            case .error(let message):
                statusText(message)
            }
        }
    }

    private func windowRow(_ window: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.title)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(window.tint)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(window.tint)
                        .frame(
                            width: max(
                                2,
                                geometry.size.width
                                    * min(1, window.usedPercent / 100)))
                }
            }
            .frame(height: 6)

            if let reset = window.resetsAt {
                Text("Resets \(Self.resetString(reset))")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.6))
    }

    /// e.g. "3:19 PM (in 2h)" today, or "Wed 8:59 PM" on another day.
    private static func resetString(_ date: Date) -> String {
        let calendar = Calendar.current
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat =
            calendar.isDateInToday(date) ? "h:mm a" : "EEE h:mm a"
        let base = timeFormatter.string(from: date)

        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return base }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        let relative = hours > 0 ? "in \(hours)h \(minutes)m" : "in \(minutes)m"
        return "\(base) (\(relative))"
    }
}

struct UsagePopup_Previews: PreviewProvider {
    static var previews: some View {
        UsagePopup()
            .previewLayout(.sizeThatFits)
    }
}
