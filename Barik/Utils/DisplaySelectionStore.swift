import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted whenever the set of displays Barik should render on changes.
    static let barikDisplaySelectionChanged = Notification.Name(
        "barikDisplaySelectionChanged")
}

extension NSScreen {
    /// The Core Graphics display identifier for this screen. Stable within a
    /// session but may change between reconnects, so it is only used as a
    /// fallback identity.
    var barikDisplayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber)?.uint32Value ?? 0
    }

    /// A human-readable, persistence-friendly key for this screen. Prefers the
    /// localized display name so a selection survives relaunches; falls back to
    /// the display ID when a name is unavailable.
    var barikDisplayKey: String {
        let name = localizedName
        if !name.isEmpty {
            return name
        }
        return "display-\(barikDisplayID)"
    }

    /// The display Barik treats as "main": the built-in display when it is
    /// connected (lid open), otherwise the primary display — the one holding
    /// the global origin, as set in System Settings > Displays.
    ///
    /// `NSScreen.main` is deliberately not used: it is the screen containing
    /// the key window, so it follows keyboard focus and can point at an
    /// external monitor right when displays are reconnected.
    static var barikPreferredMain: NSScreen? {
        screens.first { CGDisplayIsBuiltin($0.barikDisplayID) != 0 }
            ?? screens.first { $0.frame.origin == .zero }
            ?? screens.first
    }

    /// The area macOS reserves at the top of this screen (system menu bar or
    /// notch). Maximized/zoomed windows tile against `visibleFrame`, so drawing
    /// Barik's bar within this inset keeps it from overlapping them. This is
    /// per-display, so a notched main screen and a plain external screen each
    /// get their correct height.
    var barikTopInset: CGFloat {
        max(0, frame.maxY - visibleFrame.maxY)
    }

    /// The height Barik's bar should use to match this screen's system menu
    /// bar. Displays that reserve no top space (`inset == 0`, e.g. an external
    /// screen while the menu bar auto-hides) use the measured height of their
    /// own menu bar window, since it differs per display (a notched built-in
    /// screen's menu bar is taller than a plain external one's). Only when that
    /// is unavailable fall back to another display's height, then Barik's
    /// default.
    var barikMenuBarHeight: CGFloat {
        let inset = barikTopInset
        if inset >= 1 {
            return inset
        }
        if let measured = MenuBarHeightStore.shared.heights[barikDisplayKey] {
            return measured
        }
        if let reserved = NSScreen.screens.map({ $0.barikTopInset }).max(),
            reserved >= 1
        {
            return reserved
        }
        return CGFloat(Constants.menuBarHeight)
    }
}

/// Measured height of the system menu bar on each display, keyed by display
/// key. macOS keeps a menu bar window per display even while it is
/// auto-hidden (parked just above the screen), so its height can be read from
/// the window list without the menu bar being visible.
final class MenuBarHeightStore: ObservableObject {
    static let shared = MenuBarHeightStore()

    @Published private(set) var heights: [String: CGFloat] = [:]

    private init() {}

    /// Re-measures every connected display. Cheap enough to call on display
    /// configuration changes, but not meant for per-frame use.
    func refresh() {
        guard
            let windows = CGWindowListCopyWindowInfo(
                [.optionAll], kCGNullWindowID) as? [[String: Any]]
        else { return }

        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        // Window owner names don't require Screen Recording permission
        // (unlike window titles), so match on owner + level + geometry.
        let owners: Set<String> = ["Window Server", "MenuBarAgent"]
        let menuBarRects: [CGRect] = windows.compactMap { window in
            guard (window[kCGWindowLayer as String] as? Int) == menuLevel,
                let owner = window[kCGWindowOwnerName as String] as? String,
                owners.contains(owner),
                let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: boundsDict)
            else { return nil }
            return rect
        }

        var measured: [String: CGFloat] = [:]
        for screen in NSScreen.screens {
            // Window bounds use the same global coordinates as CGDisplayBounds.
            let display = CGDisplayBounds(screen.barikDisplayID)
            let height = menuBarRects
                .filter {
                    abs($0.minX - display.minX) < 1
                        && abs($0.width - display.width) < 1
                        && $0.height > 0 && $0.height < 100
                }
                .map(\.height)
                .max()
            if let height {
                measured[screen.barikDisplayKey] = height
            }
        }

        if measured != heights {
            heights = measured
        }
    }
}

/// Persists which displays Barik should render its bar on. Backed by
/// `UserDefaults` so the choice survives relaunches, and driven interactively
/// from the status bar menu.
final class DisplaySelectionStore: ObservableObject {
    static let shared = DisplaySelectionStore()

    enum Mode: String {
        /// Only the main display: the built-in screen when connected,
        /// otherwise the primary display (see `NSScreen.barikPreferredMain`).
        case main
        /// Every connected display.
        case all
        /// The explicit set of displays in `selectedKeys`.
        case selected
    }

    private let defaults = UserDefaults.standard
    private let modeKey = "barik.display.mode"
    private let selectedKey = "barik.display.selected"

    private init() {}

    var mode: Mode {
        get { Mode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .main }
        set {
            defaults.set(newValue.rawValue, forKey: modeKey)
            notifyChange()
        }
    }

    /// The display keys chosen while in `.selected` mode.
    var selectedKeys: Set<String> {
        Set(defaults.stringArray(forKey: selectedKey) ?? [])
    }

    /// Toggles an individual display on or off, switching into `.selected` mode.
    func toggle(_ key: String) {
        var keys = selectedKeys
        if keys.contains(key) {
            keys.remove(key)
        } else {
            keys.insert(key)
        }
        defaults.set(Array(keys), forKey: selectedKey)
        defaults.set(Mode.selected.rawValue, forKey: modeKey)
        notifyChange()
    }

    /// Resolves the currently connected screens Barik should render on.
    func targetScreens() -> [NSScreen] {
        switch mode {
        case .all:
            return NSScreen.screens
        case .main:
            return NSScreen.barikPreferredMain.map { [$0] } ?? []
        case .selected:
            let keys = selectedKeys
            let matched = NSScreen.screens.filter {
                keys.contains($0.barikDisplayKey)
            }
            // Fall back to the main display if none of the remembered displays
            // are currently connected, so the bar never disappears entirely.
            return matched.isEmpty
                ? (NSScreen.barikPreferredMain.map { [$0] } ?? []) : matched
        }
    }

    /// Whether the given screen is currently a render target.
    func isTargeted(_ screen: NSScreen) -> Bool {
        targetScreens().contains { $0.barikDisplayKey == screen.barikDisplayKey }
    }

    private func notifyChange() {
        // Re-render any SwiftUI views observing the store (e.g. the bar's
        // right-click menu) so checkmarks reflect the new selection.
        if Thread.isMainThread {
            objectWillChange.send()
        } else {
            DispatchQueue.main.async { self.objectWillChange.send() }
        }
        NotificationCenter.default.post(
            name: .barikDisplaySelectionChanged, object: nil)
    }
}
