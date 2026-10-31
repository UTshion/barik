import AppKit

/// Tracks the cursor to detect when macOS reveals an auto-hidden system menu
/// bar, so Barik can step aside and let the real menu bar sit on top and
/// receive clicks.
///
/// macOS reveals a hidden menu bar when the cursor touches the top edge of a
/// display and hides it again once the cursor leaves the menu bar strip. There
/// is no public API that reports this state, so the same rule is mirrored here
/// from mouse-move events.
final class MenuBarRevealMonitor {
    /// Called with the display keys whose menu bar is currently revealed.
    var onChange: ((Set<String>) -> Void)?

    private(set) var revealedKeys: Set<String> = []
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func start() {
        guard globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]
        // Mouse-move monitors don't require Accessibility permission. Global
        // events cover other apps; local events cover Barik's own panels.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) {
            [weak self] event in
            MainActor.assumeIsolated { self?.update() }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func update() {
        let location = NSEvent.mouseLocation
        var revealed = Set<String>()

        for screen in NSScreen.screens where Self.menuBarAutoHides(on: screen) {
            let frame = screen.frame
            guard location.x >= frame.minX, location.x < frame.maxX,
                location.y >= frame.minY, location.y <= frame.maxY
            else { continue }

            let key = screen.barikDisplayKey
            if location.y >= frame.maxY - 1 {
                // Touching the top edge reveals the menu bar.
                revealed.insert(key)
            } else if revealedKeys.contains(key),
                location.y >= frame.maxY - Self.menuBarHeight(on: screen)
            {
                // Stays revealed while the cursor remains inside its strip.
                revealed.insert(key)
            }
        }

        guard revealed != revealedKeys else { return }
        revealedKeys = revealed
        onChange?(revealed)
    }

    /// Whether the system menu bar on `screen` is hidden until hovered. A
    /// display reserving no top area has no persistent menu bar; otherwise
    /// fall back to the global "Automatically hide and show the menu bar"
    /// preference (notched displays keep a top inset even when it is on).
    private static func menuBarAutoHides(on screen: NSScreen) -> Bool {
        screen.barikTopInset < 1
            || UserDefaults.standard.bool(forKey: "_HIHideMenuBar")
    }

    /// Height of the revealed system menu bar on `screen`.
    private static func menuBarHeight(on screen: NSScreen) -> CGFloat {
        if let measured = MenuBarHeightStore.shared.heights[screen.barikDisplayKey] {
            return measured
        }
        return max(
            NSStatusBar.system.thickness,
            NSApp.mainMenu?.menuBarHeight ?? 0,
            screen.safeAreaInsets.top)
    }
}
