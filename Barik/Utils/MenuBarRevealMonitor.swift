import AppKit

/// Detects when macOS reveals an auto-hidden system menu bar, so Barik can
/// step aside and let the real menu bar sit on top and receive clicks.
///
/// There is no public API that reports this state. Two signals are combined:
/// - the cursor touching the top edge of a display, which is how the menu bar
///   is usually revealed and reacts instantly on mouse moves;
/// - the system menu bar window actually being on screen, polled from the
///   window list. This also catches reveals with other triggers (keyboard
///   menu access, menu bar managers such as Ice, apps opening a status item
///   menu), and keeps the display revealed while macOS still shows the menu
///   bar after the cursor left its strip (e.g. over the gap above a maximized
///   window).
final class MenuBarRevealMonitor {
    /// Called with the display keys whose menu bar is currently revealed.
    var onChange: ((Set<String>) -> Void)?

    private(set) var revealedKeys: Set<String> = []
    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// Re-checks the menu bar windows while a menu bar is revealed, so hiding
    /// is noticed even if the cursor stops moving.
    private var hidePollTimer: Timer?
    /// Slower always-on check for reveals that don't come from the cursor.
    private var revealPollTimer: Timer?
    /// When the cursor last touched the top edge of each display.
    private var lastEdgeHit: [String: Date] = [:]
    /// How long after touching the top edge the cursor's position may keep a
    /// display revealed while the menu bar window is still sliding in. After
    /// that only the window counts: Barik's widgets live in the same strip, so
    /// letting the cursor hold it would keep Barik lowered — and its clicks
    /// going to the system menu bar — whenever the user reaches for Barik.
    private static let edgeGracePeriod: TimeInterval = 0.6

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
        revealPollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.update(checkWindows: true) }
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        hidePollTimer?.invalidate()
        hidePollTimer = nil
        revealPollTimer?.invalidate()
        revealPollTimer = nil
    }

    /// - Parameter checkWindows: query the window list even when nothing is
    ///   revealed. Mouse moves arrive far too often for that, so they only do
    ///   it while something is revealed; the timers always do.
    private func update(checkWindows: Bool = false) {
        let location = NSEvent.mouseLocation
        var revealed = Set<String>()
        let visibleMenuBars =
            checkWindows || !revealedKeys.isEmpty
            ? Self.visibleSystemMenuBarKeys() : []

        for screen in NSScreen.screens where Self.menuBarAutoHides(on: screen) {
            let frame = screen.frame
            let key = screen.barikDisplayKey
            let cursorOnScreen =
                location.x >= frame.minX && location.x < frame.maxX
                && location.y >= frame.minY && location.y <= frame.maxY

            if cursorOnScreen, location.y >= frame.maxY - 1 {
                // Touching the top edge reveals the menu bar.
                lastEdgeHit[key] = Date()
                revealed.insert(key)
            } else if visibleMenuBars.contains(key) {
                // The menu bar is on screen, whatever revealed it.
                revealed.insert(key)
            } else if revealedKeys.contains(key),
                cursorOnScreen,
                location.y >= frame.maxY - Self.menuBarHeight(on: screen),
                let hit = lastEdgeHit[key],
                Date().timeIntervalSince(hit) < Self.edgeGracePeriod
            {
                // Just revealed and still inside the strip; the menu bar
                // window may not be on screen yet.
                revealed.insert(key)
            }
        }

        updateHidePolling(active: !revealed.isEmpty)

        guard revealed != revealedKeys else { return }
        revealedKeys = revealed
        onChange?(revealed)
    }

    private func updateHidePolling(active: Bool) {
        if active, hidePollTimer == nil {
            hidePollTimer = Timer.scheduledTimer(
                withTimeInterval: 0.1, repeats: true
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.update(checkWindows: true) }
            }
        } else if !active, let timer = hidePollTimer {
            timer.invalidate()
            hidePollTimer = nil
        }
    }

    /// Display keys whose system menu bar window is currently on screen.
    ///
    /// While auto-hidden, the WindowServer's menu bar window for each display
    /// is parked just above it and reported as off screen; while shown it
    /// overlaps the display's top edge. Only owner, level and bounds are read,
    /// which needs no Screen Recording permission.
    private static func visibleSystemMenuBarKeys() -> Set<String> {
        guard
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let menuBarRects: [CGRect] = windows.compactMap { window in
            guard (window[kCGWindowLayer as String] as? Int) == menuLevel,
                (window[kCGWindowOwnerName as String] as? String) == "Window Server",
                let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: boundsDict)
            else { return nil }
            return rect
        }

        var keys = Set<String>()
        for screen in NSScreen.screens {
            // Window bounds use the same global coordinates as CGDisplayBounds.
            let display = CGDisplayBounds(screen.barikDisplayID)
            let isVisible = menuBarRects.contains {
                abs($0.minX - display.minX) < 1
                    && abs($0.width - display.width) < 1
                    && $0.maxY > display.minY + 1
            }
            if isVisible {
                keys.insert(screen.barikDisplayKey)
            }
        }
        return keys
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
