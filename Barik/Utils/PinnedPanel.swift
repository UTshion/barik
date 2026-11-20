import AppKit

/// Panel for Barik's bar and background that always stays exactly where it
/// is placed.
///
/// AppKit constrains windows below the main menu level so they don't overlap
/// the menu bar area: every `setFrame` (including the resizes `NSHostingView`
/// does when the bar's content changes) pushes them down below the menu bar
/// or notch strip. Barik drops below that level while the system menu bar is
/// revealed, so a resize during that time used to shift the bar down — and it
/// stayed there, overlapping windows, after rising again. The bar deliberately
/// lives in that strip, so frame constraining is disabled.
final class PinnedPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
