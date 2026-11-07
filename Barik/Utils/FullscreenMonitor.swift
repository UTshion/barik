import AppKit

/// Detects displays whose frontmost window covers the whole screen — a
/// native full-screen app, a browser playing video full screen, a window
/// manager's fullscreen mode — so Barik can get out of the way there.
///
/// macOS has no public notification for "a window became full screen" in
/// another app, so this checks the window list on space/app switches and on
/// a light polling tick that catches in-place resizes.
final class FullscreenMonitor {
    /// Called with the display keys that currently show a full-screen window,
    /// whenever they change and on every tick while any display is full
    /// screen (so Barik can re-assert hiding after space transitions).
    var onChange: ((Set<String>) -> Void)?

    private(set) var fullscreenKeys: Set<String> = []
    private var pollTimer: Timer?
    private var observers: [any NSObjectProtocol] = []

    func start() {
        guard pollTimer == nil else { return }

        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
        ] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.updateAfterTransition() }
                })
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }

    /// Checks now and again while a space/app switch animates: the window
    /// list only settles once the full-screen transition finishes, and Barik
    /// should reappear as soon as it does rather than on the next poll.
    private func updateAfterTransition() {
        update()
        for delay in [0.15, 0.4, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.update()
            }
        }
    }

    func update() {
        let keys = Self.displaysWithFullscreenWindow()
        guard keys != fullscreenKeys || !keys.isEmpty else { return }
        fullscreenKeys = keys
        onChange?(keys)
    }

    /// Display keys whose frontmost app has a window covering the display.
    ///
    /// A native full-screen window on a notched display does not start at the
    /// top: it sits below the strip macOS keeps for the menu bar, and while a
    /// display shows a full-screen space that strip is an on-screen
    /// WindowServer window at the main-menu level (it is parked off screen
    /// otherwise). So the area to cover starts below that strip when present.
    ///
    /// The whole frontmost app is considered, not just its frontmost window:
    /// full-screen apps often put a separate toolbar window in front.
    ///
    /// Only owner, PID, layer, alpha and bounds are read, which needs no
    /// Screen Recording permission.
    private static func displaysWithFullscreenWindow() -> Set<String> {
        guard
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let normalLevel = Int(CGWindowLevelForKey(.normalWindow))
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))

        // Front-to-back order, so the first match per display belongs to the
        // frontmost app there.
        var appWindows: [(pid: pid_t, rect: CGRect)] = []
        var menuStrips: [CGRect] = []
        for window in windows {
            guard let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: boundsDict),
                let layer = window[kCGWindowLayer as String] as? Int
            else { continue }

            if layer == menuLevel,
                (window[kCGWindowOwnerName as String] as? String) == "Window Server"
            {
                menuStrips.append(rect)
            } else if layer == normalLevel,
                let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                pid != ownPID,
                (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                rect.width > 50, rect.height > 50
            {
                appWindows.append((pid, rect))
            }
        }

        var keys = Set<String>()
        for screen in NSScreen.screens {
            // Window bounds use the same global coordinates as CGDisplayBounds.
            let display = CGDisplayBounds(screen.barikDisplayID)
            guard let frontmost = appWindows.first(where: { $0.rect.intersects(display) })
            else { continue }

            // The full-screen menu bar strip on this display, if shown.
            let stripHeight =
                menuStrips
                .filter {
                    abs($0.minX - display.minX) < 1 && abs($0.width - display.width) < 1
                        && abs($0.minY - display.minY) < 1
                }
                .map(\.height)
                .max() ?? 0
            var area = display
            area.origin.y += stripHeight
            area.size.height -= stripHeight

            // Allow a point of slack for rounding.
            let target = area.insetBy(dx: 1, dy: 1)
            let covers = appWindows.contains {
                $0.pid == frontmost.pid && $0.rect.contains(target)
            }
            if covers {
                keys.insert(screen.barikDisplayKey)
            }
        }
        return keys
    }
}
