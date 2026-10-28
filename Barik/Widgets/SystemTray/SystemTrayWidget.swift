import SwiftUI

/// Widget for displaying other apps' menu bar extras (status items).
struct SystemTrayWidget: View {
    @EnvironmentObject var configProvider: ConfigProvider
    @State private var viewModel = SystemTrayViewModel()
    @State private var rect: CGRect = .zero

    private let maxInlineItems = 10

    var body: some View {
        HStack(spacing: 6) {
            if !viewModel.isTrusted {
                Button {
                    viewModel.openAccessibilitySettings()
                } label: {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Barik needs Accessibility access to show menu bar items")
            } else {
                ForEach(viewModel.trayItems.prefix(maxInlineItems)) { item in
                    Button {
                        viewModel.press(item)
                    } label: {
                        Group {
                            if let icon = viewModel.icon(for: item) {
                                Image(nsImage: icon)
                                    .resizable()
                                    .scaledToFit()
                            } else {
                                Image(systemName: "app")
                                    .resizable()
                                    .scaledToFit()
                            }
                        }
                        .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                    .help(item.name)
                }

                if viewModel.trayItems.count > maxInlineItems {
                    Button {
                        MenuBarPopup.show(rect: rect, id: "systemtray") {
                            SystemTrayPopup(viewModel: viewModel)
                        }
                    } label: {
                        Text("+\(viewModel.trayItems.count - maxInlineItems)")
                            .font(.system(size: 10))
                            .foregroundColor(.foregroundOutside)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            rect = $0
        }
        .experimentalConfiguration(cornerRadius: 15)
        .frame(maxHeight: .infinity)
        .onAppear {
            viewModel.updateConfig(configProvider.config)
            viewModel.start()
        }
        .onDisappear { viewModel.stop() }
        .onChange(of: configProvider.config) { _, newConfig in
            viewModel.updateConfig(newConfig)
        }
    }
}
