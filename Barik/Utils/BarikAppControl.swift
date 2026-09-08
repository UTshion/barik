import AppKit
import os

/// Application-level actions exposed from Barik's own bar (right-click menu)
/// and the status bar item.
enum BarikAppControl {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.barik",
        category: "BarikAppControl")

    /// Terminates Barik.
    static func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// Launches a fresh instance of Barik and then terminates the current one.
    static func restart() {
        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: bundleURL, configuration: configuration
        ) { _, error in
            if let error = error {
                logger.error(
                    "Failed to relaunch Barik: \(error.localizedDescription, privacy: .public)"
                )
            }
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
