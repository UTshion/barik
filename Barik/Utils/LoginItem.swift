import ServiceManagement
import os

/// Registers Barik as a login item through `SMAppService`, so it starts with
/// the user session after a restart. Shown under System Settings ▸ General ▸
/// Login Items & Extensions.
@MainActor
enum LoginItem {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.barik",
        category: "LoginItem")

    /// Set once Barik has made its one-time default registration, so turning
    /// the option off is respected on later launches.
    private static let configuredKey = "barik.loginItem.configured"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Enables launch at login on first run. Skipped for Debug builds so
    /// development copies in DerivedData never become login items.
    static func registerByDefaultIfNeeded() {
        #if !DEBUG
            let defaults = UserDefaults.standard
            guard !defaults.bool(forKey: configuredKey) else { return }
            setEnabled(true)
            defaults.set(true, forKey: configuredKey)
        #endif
    }

    static func setEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            logger.error(
                "Failed to \(enabled ? "register" : "unregister", privacy: .public) login item: \(error.localizedDescription, privacy: .public)"
            )
        }
        // The user may have to approve the item in System Settings first.
        if enabled, service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    static func toggle() {
        setEnabled(!isEnabled)
    }
}
