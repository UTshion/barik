import SwiftUI

struct SpacesWidget: View {
    @State private var viewModel = SpacesViewModel()

    @ObservedObject var configManager = ConfigManager.shared
    var foregroundHeight: CGFloat { configManager.config.experimental.foreground.resolveHeight() }

    /// X coordinate of this widget's leading edge in screen/global coordinates.
    @State private var widgetOriginX: CGFloat = 0

    // MARK: Drag-to-reorder state

    private static let rowSpace = "barik.spaces.row"
    /// Frames of each space in the row's coordinate space, keyed by space ID.
    @State private var spaceFrames: [String: CGRect] = [:]
    @State private var draggedSpaceId: String?
    @State private var dragOffset: CGFloat = 0
    @State private var dropTargetId: String?

    /// Maximum width this widget may occupy without entering the notch area.
    /// Nil means no constraint (non-notched screens or no detected notch apps).
    private var maxAvailableWidth: CGFloat? {
        guard let boundary = viewModel.notchLeftBoundary else { return nil }
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
        .environment(viewModel)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    @ViewBuilder
    private func spacesRow() -> some View {
        HStack(spacing: foregroundHeight < 30 ? 0 : 8) {
            ForEach(viewModel.spaces) { space in
                let isDragged = draggedSpaceId == space.id
                SpaceView(space: space)
                    .id(space.id)  // Required for ScrollViewReader.scrollTo(_:)
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .named(Self.rowSpace))
                    } action: {
                        spaceFrames[space.id] = $0
                    }
                    .overlay {
                        if dropTargetId == space.id {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.foreground.opacity(0.8), lineWidth: 1.5)
                        }
                    }
                    .offset(x: isDragged ? dragOffset : 0)
                    .scaleEffect(isDragged ? 1.05 : 1)
                    .opacity(isDragged ? 0.85 : 1)
                    .zIndex(isDragged ? 1 : 0)
                    // Taps on the space/window take precedence; the drag only
                    // begins once the pointer has moved a few points.
                    .gesture(reorderGesture(for: space))
            }
        }
        .coordinateSpace(.named(Self.rowSpace))
        .experimentalConfiguration(horizontalPadding: 5, cornerRadius: 10)
    }

    // MARK: - Drag to reorder

    /// Dragging a space onto another one swaps their windows, which reorders
    /// the workspaces as shown in the bar.
    private func reorderGesture(for space: AnySpace) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.rowSpace))
            .onChanged { value in
                draggedSpaceId = space.id
                dragOffset = value.translation.width
                let x = value.location.x
                let target = spaceFrames.first { id, frame in
                    id != space.id && frame.minX <= x && x <= frame.maxX
                }?.key
                if target != dropTargetId {
                    withAnimation(.smooth(duration: 0.15)) { dropTargetId = target }
                }
            }
            .onEnded { _ in
                if let targetId = dropTargetId,
                    let target = viewModel.spaces.first(where: { $0.id == targetId })
                {
                    viewModel.swapSpaces(space, target)
                }
                withAnimation(.smooth(duration: 0.25)) {
                    draggedSpaceId = nil
                    dragOffset = 0
                    dropTargetId = nil
                }
            }
    }
}

/// This view shows a space with its windows.
private struct SpaceView: View {
    @EnvironmentObject var configProvider: ConfigProvider
    @Environment(SpacesViewModel.self) private var viewModel

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
    @Environment(SpacesViewModel.self) private var viewModel

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
                if let appName = window.appName,
                    let icon = IconCache.shared.icon(for: appName)
                {
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
            viewModel.switchToWindow(window, in: space)
        }
        .onHover { value in
            isHovered = value
        }
    }
}
