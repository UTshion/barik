import AppKit
import Observation

@MainActor
@Observable
final class SpacesViewModel {
    private(set) var spaces: [AnySpace] = []

    /// Left edge (screen X) of the area occupied by the notch or a notch
    /// overlay app such as BoringNotch. `nil` when there is no notch.
    private(set) var notchLeftBoundary: CGFloat?

    @ObservationIgnored private let provider: (any SpacesProvider)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var notchTask: Task<Void, Never>?
    @ObservationIgnored private var spaceObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var isLoading = false

    /// Focus commands are chained so they run strictly in the order the user
    /// issued them. Otherwise a later `workspace` command could land after
    /// `focus --window-id` and steal focus back from the clicked window.
    @ObservationIgnored private var lastCommand: Task<Void, Never>?

    init() {
        let runningApps = NSWorkspace.shared.runningApplications.compactMap {
            $0.localizedName?.lowercased()
        }
        let config = ConfigManager.shared.config
        if runningApps.contains("yabai") {
            provider = YabaiSpacesProvider(executablePath: config.yabai.path)
        } else if runningApps.contains("aerospace") {
            provider = AerospaceSpacesProvider(
                executablePath: config.aerospace.path)
        } else {
            provider = nil
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard pollTask == nil else { return }

        // Refresh immediately on space switches instead of waiting for a tick.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        // 0.5s safety-net tick for changes that post no notification
        // (window opened/closed, title changes, …).
        pollTask = Task { [weak self] in
            // The loops hold `self` weakly so they end once the view model
            // is released, even if `stop()` was never called.
            while !Task.isCancelled, let self {
                self.refresh()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        notchTask = Task { [weak self] in
            while !Task.isCancelled, let self {
                await self.updateNotchBoundary()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        notchTask?.cancel()
        notchTask = nil
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
            self.spaceObserver = nil
        }
    }

    // MARK: - Loading

    private func refresh() {
        guard !isLoading, let provider else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            guard let fetched = await provider.getSpacesWithWindows() else {
                return
            }
            let sorted = fetched.sorted { lhs, rhs in
                if let l = Int(lhs.id), let r = Int(rhs.id) { return l < r }
                return lhs.id < rhs.id
            }
            // Avoid invalidating views when nothing changed.
            if sorted != spaces { spaces = sorted }
        }
    }

    // MARK: - Commands

    func switchToSpace(_ space: AnySpace, needWindowFocus: Bool = false) {
        enqueue { provider in
            await provider.focusSpace(
                spaceId: space.id, needWindowFocus: needWindowFocus)
        }
    }

    /// Switches to `space` and then focuses `window`, strictly in that order.
    func switchToWindow(_ window: AnyWindow, in space: AnySpace) {
        enqueue { provider in
            await provider.focusSpace(spaceId: space.id, needWindowFocus: false)
            await provider.focusWindow(windowId: String(window.id))
        }
    }

    private func enqueue(
        _ command: @escaping @Sendable (any SpacesProvider) async -> Void
    ) {
        guard let provider else { return }
        let previous = lastCommand
        lastCommand = Task {
            await previous?.value
            await command(provider)
            // Reflect the new focus right away.
            refresh()
        }
    }

    // MARK: - Notch boundary

    private func updateNotchBoundary() async {
        let boringNotchPID = NSWorkspace.shared.runningApplications.first {
            let name = ($0.localizedName ?? "").lowercased()
            let bundle = ($0.bundleIdentifier ?? "").lowercased()
            return name.contains("boringnotch") || name.contains("boring notch")
                || bundle.contains("boringnotch")
                || bundle.contains("boring-notch")
        }?.processIdentifier

        var boundary: CGFloat?
        if let boringNotchPID {
            boundary = await Self.menuBarWindowMinX(pid: boringNotchPID)
        }
        if boundary == nil,
            let area = NSScreen.main?.auxiliaryTopLeftArea, area.width > 0
        {
            boundary = area.maxX
        }
        if boundary != notchLeftBoundary { notchLeftBoundary = boundary }
    }

    /// Left edge of the given process's widest window sitting in the menu bar
    /// area. Querying the window server is comparatively expensive, so it runs
    /// off the main actor.
    @concurrent
    private nonisolated static func menuBarWindowMinX(pid: pid_t) async
        -> CGFloat?
    {
        guard
            let infoList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        return infoList.compactMap { info -> CGFloat? in
            guard
                info[kCGWindowOwnerPID as String] as? pid_t == pid,
                let boundsDict = info[kCGWindowBounds as String]
                    as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict),
                // Quartz coordinates: Y = 0 is the top of the primary screen.
                bounds.minY < 50, bounds.height < 120, bounds.width > 50
            else { return nil }
            return bounds.minX
        }.min()
    }
}
