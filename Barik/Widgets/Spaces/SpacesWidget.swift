import SwiftUI

struct SpacesWidget: View {
    @StateObject var viewModel = SpacesViewModel()

    @ObservedObject var configManager = ConfigManager.shared
    var foregroundHeight: CGFloat { configManager.config.experimental.foreground.resolveHeight() }

    /// X coordinate of this widget's leading edge in screen/global coordinates.
    @State private var widgetOriginX: CGFloat = 0

    // MARK: - Notch boundary

    /// Queries the on-screen window list for the BoringNotch app's notch window
    /// and returns its left edge X coordinate in screen coordinates (Quartz X = macOS X).
    /// Returns nil if BoringNotch is not running or no suitable window is found.
    private func boringNotchBoundary() -> CGFloat? {
        let runningApps = NSWorkspace.shared.runningApplications
        guard let app = runningApps.first(where: {
            let name = ($0.localizedName ?? "").lowercased()
            let bundle = ($0.bundleIdentifier ?? "").lowercased()
            return name.contains("boringnotch") || name.contains("boring notch") ||
                   bundle.contains("boringnotch") || bundle.contains("boring-notch")
        }) else { return nil }

        let targetPID = app.processIdentifier
        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        var minX: CGFloat? = nil
        for info in windowInfoList {
            guard
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                pid == targetPID,
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }

            // Only consider windows sitting in the menu bar area.
            // In Quartz coordinates, Y = 0 is the top of the primary screen (Y increases downward).
            guard bounds.minY < 50, bounds.height < 120, bounds.width > 50 else { continue }

            if minX == nil || bounds.minX < minX! {
                minX = bounds.minX
            }
        }
        return minX
    }

    /// Effective right boundary of the left-of-notch usable area in screen coordinates.
    /// Prefers BoringNotch's window edge over the hardware notch boundary from NSScreen,
    /// since BoringNotch visually extends the notch further than the physical cutout.
    private var notchLeftBoundary: CGFloat? {
        if let boundary = boringNotchBoundary() { return boundary }
        guard let area = NSScreen.main?.auxiliaryTopLeftArea, area.width > 0 else { return nil }
        return area.maxX
    }

    /// Maximum width this widget may occupy without entering the notch area.
    /// Nil means no constraint (non-notched screens or no detected notch apps).
    private var maxAvailableWidth: CGFloat? {
        guard let boundary = notchLeftBoundary else { return nil }
        let available = boundary - widgetOriginX
        return available > 0 ? available : nil
    }

    // MARK: - Focused space

    /// ID of the currently focused space, used to drive auto-scroll.
    private var focusedSpaceId: String? {
        viewModel.spaces.first {
            $0.windows.contains { $0.isFocused } || $0.isFocused
        }?.id
    }

    // MARK: - Body

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                spacesRow()
            }
            .frame(maxWidth: maxAvailableWidth)
            // Auto-scroll to the focused space whenever it changes.
            .onChange(of: focusedSpaceId) { _, newId in
                guard let id = newId else { return }
                withAnimation(.smooth(duration: 0.3)) {
                    scrollProxy.scrollTo(id)
                }
            }
        }
        // Read the widget's own X position to compute room available before the notch.
        // Using .background so the GeometryReader does not influence layout.
        .background(
            GeometryReader { geo in
                let x = geo.frame(in: .global).minX
                Color.clear
                    .onAppear { widgetOriginX = x }
                    .onChange(of: x) { _, newX in widgetOriginX = newX }
            }
        )
        .animation(.smooth(duration: 0.3), value: viewModel.spaces)
        .foregroundStyle(Color.foreground)
        .environmentObject(viewModel)
    }

    @ViewBuilder
    private func spacesRow() -> some View {
        HStack(spacing: foregroundHeight < 30 ? 0 : 8) {
            ForEach(viewModel.spaces) { space in
                SpaceView(space: space)
                    .id(space.id)  // Required for ScrollViewReader.scrollTo(_:)
            }
        }
        .experimentalConfiguration(horizontalPadding: 5, cornerRadius: 10)
    }
}

/// This view shows a space with its windows.
private struct SpaceView: View {
    @EnvironmentObject var configProvider: ConfigProvider
    @EnvironmentObject var viewModel: SpacesViewModel

    var config: ConfigData { configProvider.config }
    var spaceConfig: ConfigData { config["space"]?.dictionaryValue ?? [:] }

    @ObservedObject var configManager = ConfigManager.shared
    var foregroundHeight: CGFloat { configManager.config.experimental.foreground.resolveHeight() }

    var showKey: Bool { spaceConfig["show-key"]?.boolValue ?? true }

    let space: AnySpace
    @State var isHovered = false

    var body: some View {
        let isFocused = space.windows.contains { $0.isFocused } || space.isFocused
        fullView(isFocused: isFocused)
    }

    // MARK: - Full view

    /// Full layout with window icons and (for the focused window) the app name.
    @ViewBuilder
    private func fullView(isFocused: Bool) -> some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 10)
            if showKey {
                Text(space.id)
                    .font(.headline)
                    .frame(minWidth: 15)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer().frame(width: 5)
            }
            HStack(spacing: 2) {
                ForEach(space.windows) { window in
                    WindowView(window: window, space: space)
                }
            }
            Spacer().frame(width: 10)
        }
        .frame(height: 30)
        .background(
            foregroundHeight < 30 ?
            (isFocused
             ? Color.noActive
             : Color.clear) :
                (isFocused
                 ? Color.active
                 : isHovered ? Color.noActive : Color.noActive)
        )
        .clipShape(RoundedRectangle(cornerRadius: foregroundHeight < 30 ? 0 : 8, style: .continuous))
        .shadow(color: .shadow, radius: foregroundHeight < 30 ? 0 : 2)
        .transition(.blurReplace)
        .onTapGesture {
            viewModel.switchToSpace(space, needWindowFocus: true)
        }
        .animation(.smooth, value: isHovered)
        .onHover { value in
            isHovered = value
        }
    }
}

/// This view shows a window and its icon.
private struct WindowView: View {
    @EnvironmentObject var configProvider: ConfigProvider
    @EnvironmentObject var viewModel: SpacesViewModel

    var config: ConfigData { configProvider.config }
    var windowConfig: ConfigData { config["window"]?.dictionaryValue ?? [:] }
    var titleConfig: ConfigData {
        windowConfig["title"]?.dictionaryValue ?? [:]
    }

    var showTitle: Bool { windowConfig["show-title"]?.boolValue ?? true }
    var maxLength: Int { titleConfig["max-length"]?.intValue ?? 50 }
    var alwaysDisplayAppTitleFor: [String] { titleConfig["always-display-app-name-for"]?.arrayValue?.filter({ $0.stringValue != nil }).map { $0.stringValue! } ?? [] }

    let window: AnyWindow
    let space: AnySpace

    @State var isHovered = false

    var body: some View {
        let titleMaxLength = maxLength
        let size: CGFloat = 21
        let sameAppCount = space.windows.filter { $0.appName == window.appName }
            .count
        let title = sameAppCount > 1 && !alwaysDisplayAppTitleFor.contains { $0 == window.appName } ? window.title : (window.appName ?? "")
        let spaceIsFocused = space.windows.contains { $0.isFocused }
        HStack {
            ZStack {
                if let icon = window.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: size, height: size)
                        .shadow(
                            color: .iconShadow,
                            radius: 2
                        )
                } else {
                    Image(systemName: "questionmark.circle")
                        .resizable()
                        .frame(width: size, height: size)
                }
            }
            .opacity(spaceIsFocused && !window.isFocused ? 0.5 : 1)
            .transition(.blurReplace)

            if window.isFocused, !title.isEmpty, showTitle {
                HStack {
                    Text(
                        title.count > titleMaxLength
                            ? String(title.prefix(titleMaxLength)) + "..."
                            : title
                    )
                    .fixedSize(horizontal: true, vertical: false)
                    .shadow(color: .foregroundShadow, radius: 3)
                    .fontWeight(.semibold)
                    Spacer().frame(width: 5)
                }
                .transition(.blurReplace)
            }
        }
        .padding(.all, 2)
        .background(isHovered || (!showTitle && window.isFocused) ? .selected : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(.smooth, value: isHovered)
        .frame(height: 30)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.switchToSpace(space)
            usleep(100_000)
            viewModel.switchToWindow(window)
        }
        .onHover { value in
            isHovered = value
        }
    }
}
