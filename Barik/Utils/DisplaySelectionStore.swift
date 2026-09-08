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

    /// The area macOS reserves at the top of this screen (system menu bar or
    /// notch). Maximized/zoomed windows tile against `visibleFrame`, so drawing
    /// Barik's bar within this inset keeps it from overlapping them. This is
    /// per-display, so a notched main screen and a plain external screen each
    /// get their correct height.
    var barikTopInset: CGFloat {
        max(0, frame.maxY - visibleFrame.maxY)
    }

    /// The height Barik's bar should use to match this screen's system menu
    /// bar. Secondary displays often reserve no top space (`inset == 0`); in
    /// that case fall back to the display that does have a menu bar so the bar
    /// height stays consistent across monitors, and finally to Barik's default.
    var barikMenuBarHeight: CGFloat {
        let inset = barikTopInset
        if inset >= 1 {
            return inset
        }
        if let reserved = NSScreen.screens.map({ $0.barikTopInset }).max(),
            reserved >= 1
        {
            return reserved
        }
        return CGFloat(Constants.menuBarHeight)
    }
}

/// Persists which displays Barik should render its bar on. Backed by
/// `UserDefaults` so the choice survives relaunches, and driven interactively
/// from the status bar menu.
final class DisplaySelectionStore: ObservableObject {
    static let shared = DisplaySelectionStore()

    enum Mode: String {
        /// Only the current main display (Barik's original behavior).
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
            return NSScreen.main.map { [$0] } ?? []
        case .selected:
            let keys = selectedKeys
            let matched = NSScreen.screens.filter {
                keys.contains($0.barikDisplayKey)
            }
            // Fall back to the main display if none of the remembered displays
            // are currently connected, so the bar never disappears entirely.
            return matched.isEmpty
                ? (NSScreen.main.map { [$0] } ?? []) : matched
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
