import AppKit
import Foundation

class SpacesViewModel: ObservableObject {
    @Published var spaces: [AnySpace] = []
    private var timer: Timer?
    private var provider: AnySpacesProvider?
    private var isLoading = false

    init() {
        let runningApps = NSWorkspace.shared.runningApplications.compactMap {
            $0.localizedName?.lowercased()
        }
        if runningApps.contains("yabai") {
            provider = AnySpacesProvider(YabaiSpacesProvider())
        } else if runningApps.contains("aerospace") {
            provider = AnySpacesProvider(AerospaceSpacesProvider())
        } else {
            provider = nil
        }
        startMonitoring()

        // Refresh immediately when the user switches spaces — avoids waiting for the next tick.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleActiveSpaceChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil)
    }

    deinit {
        stopMonitoring()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func handleActiveSpaceChange() {
        loadSpaces()
    }

    private func startMonitoring() {
        // 0.5s is the safety-net tick. Space switches fire activeSpaceDidChange
        // immediately, so this only catches things like window-list changes
        // that don't post notifications.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
            [weak self] _ in
            self?.loadSpaces()
        }
        loadSpaces()
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func loadSpaces() {
        // isLoading is read/written only on main — no race.
        assert(Thread.isMainThread)
        guard !isLoading else { return }
        guard let provider = provider else { return }
        isLoading = true
        DispatchQueue.global(qos: .utility).async {
            let fetched = provider.getSpacesWithWindows()
            let sortedSpaces: [AnySpace] = (fetched ?? []).sorted { space1, space2 in
                if let id1 = Int(space1.id), let id2 = Int(space2.id) {
                    return id1 < id2
                }
                return space1.id < space2.id
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.spaces = sortedSpaces
                self.isLoading = false
            }
        }
    }

    func switchToSpace(_ space: AnySpace, needWindowFocus: Bool = false) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.provider?.focusSpace(
                spaceId: space.id, needWindowFocus: needWindowFocus)
        }
    }

    func switchToWindow(_ window: AnyWindow) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.provider?.focusWindow(windowId: String(window.id))
        }
    }
}

class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()
    private init() {}
    func icon(for appName: String) -> NSImage? {
        if let cached = cache.object(forKey: appName as NSString) {
            return cached
        }
        let workspace = NSWorkspace.shared
        if let app = workspace.runningApplications.first(where: {
            $0.localizedName == appName
        }),
            let bundleURL = app.bundleURL
        {
            let icon = workspace.icon(forFile: bundleURL.path)
            cache.setObject(icon, forKey: appName as NSString)
            return icon
        }
        return nil
    }
}
