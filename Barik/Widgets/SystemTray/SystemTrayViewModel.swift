import AppKit
import ApplicationServices
import Observation

/// A real status item ("menu extra") owned by another app, discovered through
/// the Accessibility API.
struct TrayItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let bundleId: String
    let pid: pid_t
    fileprivate let element: AXElement

    static func == (lhs: TrayItem, rhs: TrayItem) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
    }
}

/// `AXUIElement` is an immutable CF reference that is safe to message from any
/// thread; the wrapper only exists to carry it across actors.
nonisolated struct AXElement: @unchecked Sendable {
    let raw: AXUIElement
}

/// Monitors other apps' menu bar extras and lets Barik press them.
///
/// Since macOS 26 the system menu bar is drawn by MenuBarAgent and status items
/// can no longer be found via window heuristics; the Accessibility tree
/// (`AXExtrasMenuBar`) is the supported way to enumerate and activate them.
/// Pressing an item opens its real menu, exactly like clicking it in the
/// native menu bar.
@MainActor
@Observable
final class SystemTrayViewModel {
    private(set) var trayItems: [TrayItem] = []
    private(set) var isTrusted = AXIsProcessTrusted()

    @ObservationIgnored private var allowedApps: Set<String> = []
    @ObservationIgnored private var deniedApps: Set<String> = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var isLoading = false

    init(config: ConfigData = [:]) {
        applyConfig(config)
    }

    // MARK: - Lifecycle

    func start() {
        guard pollTask == nil else { return }
        requestAccessIfNeeded()

        // App launches/quits are the main source of tray changes; a slow
        // safety-net tick covers apps that add or remove items later.
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
        }

        pollTask = Task { [weak self] in
            while !Task.isCancelled, let self {
                self.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        observers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers.removeAll()
    }

    func updateConfig(_ config: ConfigData) {
        applyConfig(config)
        refresh()
    }

    private func applyConfig(_ config: ConfigData) {
        allowedApps = Set(
            config["allowed-apps"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        deniedApps = Set(
            config["denied-apps"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    // MARK: - Accessibility permission

    private func requestAccessIfNeeded() {
        guard !AXIsProcessTrusted() else {
            isTrusted = true
            return
        }
        let options =
            ["AXTrustedCheckOptionPrompt": true]
            as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        if let url = URL(
            string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Loading

    private func refresh() {
        isTrusted = AXIsProcessTrusted()
        guard isTrusted, !isLoading else { return }
        isLoading = true

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let candidates: [AppCandidate] = NSWorkspace.shared.runningApplications
            .compactMap { app in
                guard app.processIdentifier != ownPID,
                    let bundleId = app.bundleIdentifier,
                    let name = app.localizedName,
                    isAllowed(name: name, bundleId: bundleId)
                else { return nil }
                return AppCandidate(
                    pid: app.processIdentifier, name: name, bundleId: bundleId)
            }

        Task {
            defer { isLoading = false }
            let items = await Self.collectItems(from: candidates)
            if items != trayItems { trayItems = items }
        }
    }

    private func isAllowed(name: String, bundleId: String) -> Bool {
        if !allowedApps.isEmpty, !allowedApps.contains(name),
            !allowedApps.contains(bundleId)
        {
            return false
        }
        return !deniedApps.contains(name) && !deniedApps.contains(bundleId)
    }

    nonisolated private struct AppCandidate: Sendable {
        let pid: pid_t
        let name: String
        let bundleId: String
    }

    /// Walks each app's `AXExtrasMenuBar`. AX calls are synchronous IPC to the
    /// target app, so this runs off the main actor with a short timeout to
    /// keep one hung app from stalling the scan.
    @concurrent
    nonisolated private static func collectItems(from apps: [AppCandidate])
        async -> [TrayItem]
    {
        var items: [TrayItem] = []
        for app in apps {
            let appElement = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(appElement, 0.25)

            guard
                let extras: AXUIElement = appElement.attribute(
                    "AXExtrasMenuBar"),
                let children: [AXUIElement] = extras.attribute(
                    kAXChildrenAttribute)
            else { continue }

            for (index, child) in children.enumerated() {
                let label =
                    [
                        child.attribute(kAXDescriptionAttribute) as String?,
                        child.attribute(kAXTitleAttribute) as String?,
                        child.attribute(kAXHelpAttribute) as String?,
                    ]
                    .compactMap { $0 }
                    .first { !$0.isEmpty } ?? app.name
                items.append(
                    TrayItem(
                        id: "\(app.bundleId)#\(index)",
                        name: label == app.name ? app.name : "\(app.name) — \(label)",
                        bundleId: app.bundleId,
                        pid: app.pid,
                        element: AXElement(raw: child)))
            }
        }
        return items.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Actions

    func icon(for item: TrayItem) -> NSImage? {
        NSRunningApplication(processIdentifier: item.pid)?.icon
    }

    /// Opens the item's menu, as if it were clicked in the native menu bar.
    func press(_ item: TrayItem) {
        let element = item.element
        Task { @concurrent in
            let result = AXUIElementPerformAction(
                element.raw, kAXPressAction as CFString)
            if result != .success {
                // Some extras only expose AXShowMenu.
                _ = AXUIElementPerformAction(
                    element.raw, kAXShowMenuAction as CFString)
            }
        }
    }
}

nonisolated extension AXUIElement {
    fileprivate func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(self, name as CFString, &value)
                == .success
        else { return nil }
        return value as? T
    }
}
