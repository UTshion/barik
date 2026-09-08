import SwiftUI

struct MenuBarView: View {
    @ObservedObject var configManager = ConfigManager.shared
    @ObservedObject var displayStore = DisplaySelectionStore.shared

    /// The display this bar instance is rendered on, used to size the bar to
    /// that screen's system menu bar height. `nil` falls back to the main screen.
    var displayKey: String? = nil

    /// Resolves the current `NSScreen` for `displayKey` live, so resolution
    /// changes are picked up even when the hosting panel is reused.
    private var screen: NSScreen? {
        guard let displayKey else { return NSScreen.main }
        return NSScreen.screens.first { $0.barikDisplayKey == displayKey }
            ?? NSScreen.main
    }

    var body: some View {
        let theme: ColorScheme? =
            switch configManager.config.rootToml.theme {
            case "dark":
                .dark
            case "light":
                .light
            default:
                .none
            }

        let items = configManager.config.rootToml.widgets.displayed

        HStack(spacing: 0) {
            HStack(spacing: configManager.config.experimental.foreground.spacing) {
                ForEach(0..<items.count, id: \.self) { index in
                    let item = items[index]
                    buildView(for: item)
                }
            }

            if !items.contains(where: { $0.id == "system-banner" }) {
                SystemBannerWidget(withLeftPadding: true)
            }
        }
        .foregroundStyle(Color.foregroundOutside)
        .frame(height: max(configManager.config.experimental.foreground.resolveHeight(for: screen), 1.0))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, configManager.config.experimental.foreground.horizontalPadding)
        .background(.black.opacity(0.001))
        .preferredColorScheme(theme)
        .contextMenu { barikContextMenu }
    }

    /// Right-click menu on Barik's own bar: display selection plus
    /// restart/quit. Barik covers the native menu bar, so this is the reliable
    /// way to reach these controls.
    @ViewBuilder
    private var barikContextMenu: some View {
        let store = DisplaySelectionStore.shared

        Menu("Displays") {
            Toggle(
                "All Displays",
                isOn: Binding(
                    get: { store.mode == .all },
                    set: { if $0 { store.mode = .all } }))
            Toggle(
                "Main Display Only",
                isOn: Binding(
                    get: { store.mode == .main },
                    set: { if $0 { store.mode = .main } }))

            Divider()

            ForEach(NSScreen.screens, id: \.barikDisplayKey) { screen in
                Toggle(
                    screen.localizedName,
                    isOn: Binding(
                        get: { store.isTargeted(screen) },
                        set: { _ in store.toggle(screen.barikDisplayKey) }))
            }
        }

        Divider()

        Button("Restart Barik") { BarikAppControl.restart() }
        Button("Quit Barik") { BarikAppControl.quit() }
    }

    @ViewBuilder
    private func buildView(for item: TomlWidgetItem) -> some View {
        let config = ConfigProvider(
            config: configManager.resolvedWidgetConfig(for: item))

        switch item.id {
        case "default.spaces":
            SpacesWidget().environmentObject(config)

        case "default.network":
            NetworkWidget().environmentObject(config)

        case "default.battery":
            BatteryWidget().environmentObject(config)

        case "default.time":
            TimeWidget(calendarManager: CalendarManager(configProvider: config))
                .environmentObject(config)
            
        case "default.nowplaying":
            NowPlayingWidget()
                .environmentObject(config)

        case "default.audio":
            AudioWidget()
                .environmentObject(config)

        case "default.systemtray":
            SystemTrayWidget()
                .environmentObject(config)

        case "custom.command":
            CustomCommandWidget()
                .environmentObject(config)

        case "spacer":
            Spacer().frame(minWidth: 50, maxWidth: .infinity)

        case "divider":
            Rectangle()
                .fill(Color.active)
                .frame(width: 2, height: 15)
                .clipShape(Capsule())

        case "system-banner":
            SystemBannerWidget()

        default:
            Text("?\(item.id)?").foregroundColor(.red)
        }
    }
}
