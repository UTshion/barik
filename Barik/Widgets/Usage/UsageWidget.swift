import SwiftUI

/// Claude's terracotta brand color, used for its logo mark.
extension Color {
    static let claudeAccent = Color(red: 0.85, green: 0.47, blue: 0.34)
}

/// A lightweight rendition of Claude's radial "sunburst" logo mark.
struct ClaudeMark: View {
    var color: Color = .claudeAccent

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2
            let spokes = 12
            for index in 0..<spokes {
                let angle = Double(index) / Double(spokes) * 2 * .pi
                var path = Path()
                path.move(
                    to: CGPoint(
                        x: center.x + cos(angle) * radius * 0.28,
                        y: center.y + sin(angle) * radius * 0.28))
                path.addLine(
                    to: CGPoint(
                        x: center.x + cos(angle) * radius,
                        y: center.y + sin(angle) * radius))
                context.stroke(
                    path, with: .color(color),
                    style: StrokeStyle(
                        lineWidth: max(1, radius * 0.16), lineCap: .round))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// The bar icon for a provider. Falls back to an SF Symbol for providers
/// without a bespoke mark.
struct UsageProviderIcon: View {
    let providerId: String
    var size: CGFloat = 15

    var body: some View {
        Group {
            switch providerId {
            case "claude":
                ClaudeMark()
            default:
                Image(systemName: "gauge.with.needle")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
    }
}

/// Menu-bar widget showing per-provider usage marks. Tapping toggles the
/// detailed usage popup, like the other widgets.
struct UsageWidget: View {
    @ObservedObject private var viewModel = UsageViewModel.shared
    @State private var rect: CGRect = .zero

    var body: some View {
        HStack(spacing: 10) {
            ForEach(viewModel.snapshots) { snapshot in
                providerBadge(snapshot)
            }
        }
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { rect = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { _, newValue in
                        rect = newValue
                    }
            }
        )
        .contentShape(Rectangle())
        .font(.system(size: 15))
        .experimentalConfiguration(cornerRadius: 15)
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.001))
        .onAppear { viewModel.start() }
        .onTapGesture {
            MenuBarPopup.show(rect: rect, id: "usage") { UsagePopup() }
        }
    }

    @ViewBuilder
    private func providerBadge(_ snapshot: ProviderUsageSnapshot) -> some View {
        HStack(spacing: 4) {
            UsageProviderIcon(providerId: snapshot.providerId)
                .opacity(snapshot.status == .ok ? 1 : 0.45)

            switch snapshot.status {
            case .ok:
                if let window = snapshot.tightestWindow {
                    Text("\(Int(window.usedPercent.rounded()))%")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(
                            window.isWarning ? window.tint : .foregroundOutside)
                }
            case .loading:
                EmptyView()
            case .notSignedIn, .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct UsageWidget_Previews: PreviewProvider {
    static var previews: some View {
        UsageWidget()
            .frame(width: 200, height: 60)
            .background(Color.black)
    }
}
