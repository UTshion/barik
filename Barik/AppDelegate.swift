import SwiftUI
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "app.barik",
    category: "AppDelegate")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// One background/menu-bar panel pair per targeted display, keyed by the
    /// screen's stable display key.
    private var backgroundPanels: [String: NSPanel] = [:]
    private var menuBarPanels: [String: NSPanel] = [:]

    private var statusItem: NSStatusItem?
    private weak var displaysMenu: NSMenu?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Hide from Dock and App Switcher so the app runs as a background agent.
        // Must be set before applicationDidFinishLaunching to take effect reliably.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let error = ConfigManager.shared.initError {
            logger.error("Config initialization error: \(error, privacy: .public)")
            showFatalConfigError(message: error)
            return
        }

        // Show "What's New" banner if the app version is outdated
        if !VersionChecker.isLatestVersion() {
            VersionChecker.updateVersionFile()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NotificationCenter.default.post(
                    name: Notification.Name("ShowWhatsNewBanner"), object: nil)
            }
        }

        MenuBarPopup.setup()
        setupStatusItem()
        setupPanels()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)

        // Rebuild panels when the user changes the display selection.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displaySelectionDidChange(_:)),
            name: .barikDisplaySelectionChanged,
            object: nil)

        // Re-display panels after the display wakes from sleep.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screensDidWake(_:)),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil)

        // Also handle system-level wake (lid open, etc.) — panels can lose their
        // level association after a long sleep and silently disappear.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil)

        // Surface main-thread stalls to Console.app for diagnosing freezes.
        MainThreadStallDetector.shared.start()

        logger.info("Barik launched successfully")
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        logger.info("Screen parameters changed, reconfiguring panels")
        setupPanels()
    }

    @objc private func displaySelectionDidChange(_ notification: Notification) {
        logger.info("Display selection changed, reconfiguring panels")
        setupPanels()
    }

    @objc private func screensDidWake(_ notification: Notification) {
        logger.info("Screens woke from sleep, reconfiguring panels")
        setupPanels()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        logger.info("System woke from sleep, reconfiguring panels")
        setupPanels()
    }

    // MARK: - Panels

    /// Configures and displays the background and menu bar panels on every
    /// currently targeted display, tearing down panels for displays that are
    /// no longer selected or connected.
    private func setupPanels() {
        let screens = DisplaySelectionStore.shared.targetScreens()
        let wantedKeys = Set(screens.map { $0.barikDisplayKey })

        for key in backgroundPanels.keys where !wantedKeys.contains(key) {
            backgroundPanels[key]?.orderOut(nil)
            backgroundPanels[key] = nil
        }
        for key in menuBarPanels.keys where !wantedKeys.contains(key) {
            menuBarPanels[key]?.orderOut(nil)
            menuBarPanels[key] = nil
        }

        for screen in screens {
            let key = screen.barikDisplayKey
            setupPanel(
                &backgroundPanels[key],
                frame: screen.frame,
                level: Int(CGWindowLevelForKey(.desktopWindow)),
                hostingRootView: AnyView(BackgroundView(displayKey: key)))
            setupPanel(
                &menuBarPanels[key],
                frame: screen.frame,
                level: Int(CGWindowLevelForKey(.backstopMenu)),
                hostingRootView: AnyView(MenuBarView(displayKey: key)))
        }
    }

    /// Sets up an NSPanel with the provided parameters.
    private func setupPanel(
        _ panel: inout NSPanel?, frame: CGRect, level: Int,
        hostingRootView: AnyView
    ) {
        if let existingPanel = panel {
            existingPanel.setFrame(frame, display: true)
            // Re-assert level: after long sleeps macOS can demote panels and
            // they vanish behind other windows. Re-setting forces the level back.
            existingPanel.level = NSWindow.Level(rawValue: level)
            existingPanel.setIsVisible(true)
            existingPanel.orderFront(nil)
            return
        }

        let newPanel = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false)
        newPanel.level = NSWindow.Level(rawValue: level)
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        newPanel.contentView = NSHostingView(rootView: hostingRootView)
        newPanel.orderFront(nil)
        panel = newPanel
    }

    // MARK: - Status bar menu

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "menubar.rectangle",
                accessibilityDescription: "Barik")
            button.toolTip = "Barik"
        }
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let displaysItem = NSMenuItem(
            title: "Displays", action: nil, keyEquivalent: "")
        let displaysSubmenu = NSMenu(title: "Displays")
        displaysSubmenu.delegate = self
        displaysItem.submenu = displaysSubmenu
        self.displaysMenu = displaysSubmenu
        menu.addItem(displaysItem)

        menu.addItem(.separator())

        let restartItem = NSMenuItem(
            title: "Restart Barik", action: #selector(restartBarik),
            keyEquivalent: "r")
        restartItem.target = self
        menu.addItem(restartItem)

        let quitItem = NSMenuItem(
            title: "Quit Barik", action: #selector(quitBarik),
            keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    /// Rebuilds the Displays submenu each time it opens so it reflects the
    /// currently connected screens and the active selection.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === displaysMenu else { return }
        menu.removeAllItems()

        let store = DisplaySelectionStore.shared

        let allItem = NSMenuItem(
            title: "All Displays", action: #selector(selectAllDisplays),
            keyEquivalent: "")
        allItem.target = self
        allItem.state = store.mode == .all ? .on : .off
        menu.addItem(allItem)

        let mainItem = NSMenuItem(
            title: "Main Display Only", action: #selector(selectMainDisplay),
            keyEquivalent: "")
        mainItem.target = self
        mainItem.state = store.mode == .main ? .on : .off
        menu.addItem(mainItem)

        menu.addItem(.separator())

        for screen in NSScreen.screens {
            let item = NSMenuItem(
                title: screen.localizedName,
                action: #selector(toggleDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = screen.barikDisplayKey
            item.state = store.isTargeted(screen) ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func selectAllDisplays() {
        DisplaySelectionStore.shared.mode = .all
    }

    @objc private func selectMainDisplay() {
        DisplaySelectionStore.shared.mode = .main
    }

    @objc private func toggleDisplay(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        DisplaySelectionStore.shared.toggle(key)
    }

    @objc private func quitBarik() {
        BarikAppControl.quit()
    }

    @objc private func restartBarik() {
        BarikAppControl.restart()
    }

    private func showFatalConfigError(message: String) {
        let alert = NSAlert()
        alert.messageText = "Configuration Error"
        alert.informativeText = "\(message)\n\nPlease double check ~/.barik-config.toml and try again."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")

        alert.runModal()
        NSApplication.shared.terminate(nil)
    }
}
