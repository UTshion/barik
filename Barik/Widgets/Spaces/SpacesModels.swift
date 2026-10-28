import AppKit

nonisolated protocol SpaceModel: Identifiable, Equatable, Decodable, Sendable {
    associatedtype WindowType: WindowModel
    /// Identifier passed back to the window manager to focus this space.
    var spaceId: String { get }
    var isFocused: Bool { get set }
    var windows: [WindowType] { get set }
}

nonisolated protocol WindowModel: Identifiable, Equatable, Decodable, Sendable {
    var id: Int { get }
    var title: String { get }
    var appName: String? { get }
    var isFocused: Bool { get }
}

/// A window manager backend (yabai, AeroSpace, …).
///
/// Implementations run their CLI calls through `SubprocessRunner`'s async API,
/// so none of these methods block the main actor or the cooperative pool.
nonisolated protocol SpacesProvider: Sendable {
    @concurrent func getSpacesWithWindows() async -> [AnySpace]?
    @concurrent func focusSpace(spaceId: String, needWindowFocus: Bool) async
    @concurrent func focusWindow(windowId: String) async
}

nonisolated struct AnyWindow: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let appName: String?
    let isFocused: Bool

    init<W: WindowModel>(_ window: W) {
        self.id = window.id
        self.title = window.title
        self.appName = window.appName
        self.isFocused = window.isFocused
    }
}

nonisolated struct AnySpace: Identifiable, Equatable, Sendable {
    let id: String
    let isFocused: Bool
    let windows: [AnyWindow]

    init<S: SpaceModel>(_ space: S) {
        self.id = space.spaceId
        self.isFocused = space.isFocused
        self.windows = space.windows.map { AnyWindow($0) }
    }
}

/// Resolves and caches application icons by app name.
@MainActor
final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()
    private init() {}

    func icon(for appName: String) -> NSImage? {
        if let cached = cache.object(forKey: appName as NSString) {
            return cached
        }
        let workspace = NSWorkspace.shared
        guard
            let app = workspace.runningApplications.first(where: {
                $0.localizedName == appName
            }),
            let bundleURL = app.bundleURL
        else { return nil }
        let icon = workspace.icon(forFile: bundleURL.path)
        cache.setObject(icon, forKey: appName as NSString)
        return icon
    }
}
