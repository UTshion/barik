import AppKit
import Combine
import Foundation

/// View model for monitoring and displaying system tray (menu bar) applications.
class SystemTrayViewModel: ObservableObject {
    @Published var trayItems: [TrayItem] = []
    
    private var timer: Timer?
    private var knownMenuBarApps: Set<String> = []
    
    init() {
        // Common menu bar applications that typically show in system tray
        knownMenuBarApps = Set([
            "Dropbox", "Slack", "Spotify", "Discord", "Telegram",
            "WhatsApp", "Skype", "Zoom", "Microsoft Teams",
            "Bartender", "Alfred", "Raycast", "1Password",
            "NordVPN", "ExpressVPN", "Surfshark",
            "CleanMyMac", "Little Snitch", "Bartender",
            "iStat Menus", "Stats", "MenuMeters",
            "Time Machine", "AirDrop", "Bluetooth",
            "WiFi", "Battery", "Volume", "Clock"
        ])
        
        startMonitoring()
    }
    
    deinit {
        stopMonitoring()
    }
    
    private func startMonitoring() {
        updateTrayItems()
        
        // Update every 2 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateTrayItems()
        }
    }
    
    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
    
    private func updateTrayItems() {
        DispatchQueue.global(qos: .background).async {
            let runningApps = NSWorkspace.shared.runningApplications
            var items: [TrayItem] = []
            
            for app in runningApps {
                guard let bundleIdentifier = app.bundleIdentifier,
                      let appName = app.localizedName else {
                    continue
                }
                
                // Check if app is likely to have a menu bar item
                if shouldShowInTray(appName: appName, bundleId: bundleIdentifier) {
                    if let icon = app.icon {
                        let item = TrayItem(
                            id: bundleIdentifier,
                            name: appName,
                            icon: icon,
                            bundleId: bundleIdentifier
                        )
                        items.append(item)
                    }
                }
            }
            
            // Sort by name
            items.sort { $0.name < $1.name }
            
            DispatchQueue.main.async {
                self.trayItems = items
            }
        }
    }
    
    private func shouldShowInTray(appName: String, bundleId: String) -> Bool {
        // Check if it's a known menu bar app
        if knownMenuBarApps.contains(appName) {
            return true
        }
        
        // Check bundle identifier patterns
        let menuBarPatterns = [
            "com.apple.menuextra",
            "com.spotify",
            "com.tinyspeck.slackmacgap",
            "com.hnc.Discord",
            "com.microsoft.teams",
            "com.zoom",
            "com.dropbox",
            "com.1password",
            "com.raycast",
            "com.alfredapp"
        ]
        
        for pattern in menuBarPatterns {
            if bundleId.lowercased().contains(pattern.lowercased()) {
                return true
            }
        }
        
        // Check if app has LSUIElement set (menu bar only apps)
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
           let bundle = Bundle(url: appURL),
           bundle.infoDictionary?["LSUIElement"] as? Bool == true {
            return true
        }
        
        return false
    }
    
    func openApp(_ item: TrayItem) {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleId) {
            NSWorkspace.shared.open(appURL)
        }
    }
}

struct TrayItem: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: NSImage
    let bundleId: String
    
    static func == (lhs: TrayItem, rhs: TrayItem) -> Bool {
        lhs.id == rhs.id
    }
}
