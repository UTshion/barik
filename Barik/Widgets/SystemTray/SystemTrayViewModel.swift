import AppKit
import CoreGraphics
import Foundation

/// View model for monitoring and displaying system tray (menu bar) applications.
class SystemTrayViewModel: ObservableObject {
    @Published var trayItems: [TrayItem] = []
    
    private var timer: Timer?
    private var knownMenuBarApps: Set<String> = []
    private var allowedApps: Set<String> = []
    private var deniedApps: Set<String> = []
    private var useWindowDetection: Bool = true
    
    init(config: ConfigData = [:]) {
        // Load configuration
        if let allowed = config["allowed-apps"]?.arrayValue {
            allowedApps = Set(allowed.compactMap { $0.stringValue })
        }
        if let denied = config["denied-apps"]?.arrayValue {
            deniedApps = Set(denied.compactMap { $0.stringValue })
        }
        useWindowDetection = config["use-window-detection"]?.boolValue ?? true
        
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
        DispatchQueue.global(qos: .background).async { [self] in
            var items: [TrayItem] = []
            
            // Method 1: Use CGWindowListCopyWindowInfo to detect menu bar windows
            if self.useWindowDetection {
                items.append(contentsOf: self.detectMenuBarWindows())
            }
            
            // Method 2: Check running applications
            let runningApps = NSWorkspace.shared.runningApplications
            var appItems: [TrayItem] = []
            
            for app in runningApps {
                guard let bundleIdentifier = app.bundleIdentifier,
                      let appName = app.localizedName else {
                    continue
                }
                
                // Skip if already detected via window detection
                if items.contains(where: { $0.bundleId == bundleIdentifier }) {
                    continue
                }
                
                // Check if app is likely to have a menu bar item
                if self.shouldShowInTray(appName: appName, bundleId: bundleIdentifier) {
                    if let icon = app.icon {
                        let item = TrayItem(
                            id: bundleIdentifier,
                            name: appName,
                            icon: icon,
                            bundleId: bundleIdentifier
                        )
                        appItems.append(item)
                    }
                }
            }
            
            // Combine and deduplicate
            var allItems = items
            for appItem in appItems {
                if !allItems.contains(where: { $0.bundleId == appItem.bundleId }) {
                    allItems.append(appItem)
                }
            }
            
            // Sort by name
            allItems.sort { $0.name < $1.name }
            
            DispatchQueue.main.async {
                self.trayItems = allItems
            }
        }
    }
    
    /// Detects menu bar windows using CGWindowListCopyWindowInfo
    private func detectMenuBarWindows() -> [TrayItem] {
        var items: [TrayItem] = []
        
        // Get menu bar height (typically 22-25 pixels)
        guard let screen = NSScreen.main else { return items }
        let menuBarHeight: CGFloat = 25
        
        // Get all windows
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return items
        }
        
        let screenFrame = screen.frame
        let menuBarFrame = CGRect(
            x: 0,
            y: screenFrame.height - menuBarHeight,
            width: screenFrame.width,
            height: menuBarHeight
        )
        
        for windowInfo in windowList {
            guard let bounds = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat,
                  let y = bounds["Y"] as? CGFloat,
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat else {
                continue
            }
            
            let windowFrame = CGRect(x: x, y: y, width: width, height: height)
            
            // Check if window is in menu bar area
            if menuBarFrame.intersects(windowFrame) && height <= menuBarHeight + 5 {
                // Try to get owner name
                if let ownerName = windowInfo[kCGWindowOwnerName as String] as? String,
                   let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int32 {
                    
                    // Skip system processes
                    if ownerName == "WindowServer" || ownerName == "Dock" {
                        continue
                    }
                    
                    // Get app from PID
                    if let app = NSRunningApplication(processIdentifier: ownerPID),
                       let bundleId = app.bundleIdentifier,
                       let appName = app.localizedName {
                        
                        // Apply allow/deny lists
                        if !allowedApps.isEmpty && !allowedApps.contains(appName) && !allowedApps.contains(bundleId) {
                            continue
                        }
                        if deniedApps.contains(appName) || deniedApps.contains(bundleId) {
                            continue
                        }
                        
                        if let icon = app.icon {
                            let item = TrayItem(
                                id: bundleId,
                                name: appName,
                                icon: icon,
                                bundleId: bundleId
                            )
                            items.append(item)
                        }
                    }
                }
            }
        }
        
        return items
    }
    
    private func shouldShowInTray(appName: String, bundleId: String) -> Bool {
        // Apply allow/deny lists first
        if !allowedApps.isEmpty {
            if !allowedApps.contains(appName) && !allowedApps.contains(bundleId) {
                return false
            }
        }
        if deniedApps.contains(appName) || deniedApps.contains(bundleId) {
            return false
        }
        
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
    
    func updateConfig(_ config: ConfigData) {
        // Update configuration
        if let allowed = config["allowed-apps"]?.arrayValue {
            allowedApps = Set(allowed.compactMap { $0.stringValue })
        }
        if let denied = config["denied-apps"]?.arrayValue {
            deniedApps = Set(denied.compactMap { $0.stringValue })
        }
        useWindowDetection = config["use-window-detection"]?.boolValue ?? true
        
        // Trigger update
        updateTrayItems()
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
