import CoreLocation
import CoreWLAN
import Network
import SwiftUI

nonisolated enum NetworkState: String, Sendable {
    case connected = "Connected"
    case connectedWithoutInternet = "No Internet"
    case connecting = "Connecting"
    case disconnected = "Disconnected"
    case disabled = "Disabled"
    case notSupported = "Not Supported"
}

nonisolated enum WifiSignalStrength: String, Sendable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case unknown = "Unknown"
}

/// Unified view model for monitoring network and Wi‑Fi status.
///
/// Event-driven:
/// - Overall reachability via `NWPathMonitor`.
/// - Wi‑Fi details (SSID/RSSI/channel) via `CWEventDelegate`.
///
/// Shared by the widget and popup on every display, so there is exactly one
/// path monitor and one CoreWLAN subscription for the whole app.
@MainActor
@Observable
final class NetworkStatusViewModel: NSObject, CLLocationManagerDelegate,
    CWEventDelegate
{
    static let shared = NetworkStatusViewModel()

    private(set) var wifiState: NetworkState = .disconnected
    private(set) var ethernetState: NetworkState = .disconnected

    private(set) var ssid: String = "Not connected"
    private(set) var rssi: Int = 0
    private(set) var noise: Int = 0
    private(set) var channel: String = "N/A"

    var wifiSignalStrength: WifiSignalStrength {
        if ssid == "Not connected" || ssid == "No interface" {
            return .unknown
        }
        if rssi >= -50 { return .high }
        if rssi >= -70 { return .medium }
        return .low
    }

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let monitorQueue = DispatchQueue(
        label: "NetworkMonitor")
    @ObservationIgnored private let wifiClient = CWWiFiClient.shared()
    @ObservationIgnored private var safetyTask: Task<Void, Never>?
    @ObservationIgnored private let locationManager = CLLocationManager()

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.requestWhenInUseAuthorization()
        startNetworkMonitoring()
        startWiFiMonitoring()
    }

    // MARK: — NWPathMonitor for overall network status.

    private func startNetworkMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = Self.state(of: .wifi, in: path, fallback: .connectedWithoutInternet)
            let ethernet = Self.state(of: .wiredEthernet, in: path, fallback: .disconnected)
            Task { @MainActor in
                guard let self else { return }
                if self.wifiState != wifi { self.wifiState = wifi }
                if self.ethernetState != ethernet { self.ethernetState = ethernet }
            }
        }
        monitor.start(queue: monitorQueue)
    }

    private nonisolated static func state(
        of type: NWInterface.InterfaceType, in path: NWPath,
        fallback: NetworkState
    ) -> NetworkState {
        guard path.availableInterfaces.contains(where: { $0.type == type })
        else { return .notSupported }
        guard path.usesInterfaceType(type) else { return .disconnected }
        switch path.status {
        case .satisfied: return .connected
        case .requiresConnection: return .connecting
        default: return fallback
        }
    }

    // MARK: — CoreWLAN event monitoring

    private func startWiFiMonitoring() {
        wifiClient.delegate = self
        do {
            try wifiClient.startMonitoringEvent(with: .ssidDidChange)
            try wifiClient.startMonitoringEvent(with: .bssidDidChange)
            try wifiClient.startMonitoringEvent(with: .linkDidChange)
            try wifiClient.startMonitoringEvent(with: .linkQualityDidChange)
            try wifiClient.startMonitoringEvent(with: .powerDidChange)
        } catch {
            print("CWWiFiClient.startMonitoringEvent failed: \(error)")
        }

        // 30s safety net (cheap — same off-main IPC).
        safetyTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshWiFiInfo()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Reads CoreWLAN off the main actor (wifid IPC can be slow) and publishes
    /// the result back on the main actor.
    private func refreshWiFiInfo() {
        Task {
            let snapshot = await Self.readSnapshot()
            if ssid != snapshot.ssid { ssid = snapshot.ssid }
            if rssi != snapshot.rssi { rssi = snapshot.rssi }
            if noise != snapshot.noise { noise = snapshot.noise }
            if channel != snapshot.channel { channel = snapshot.channel }
        }
    }

    private struct WiFiSnapshot: Sendable {
        let ssid: String
        let rssi: Int
        let noise: Int
        let channel: String
    }

    @concurrent
    private nonisolated static func readSnapshot() async -> WiFiSnapshot {
        guard let interface = CWWiFiClient.shared().interface() else {
            return WiFiSnapshot(
                ssid: "No interface", rssi: 0, noise: 0, channel: "N/A")
        }
        let ssidValue = interface.ssid() ?? "Not connected"
        let rssiValue = interface.rssiValue()
        let noiseValue = interface.noiseMeasurement()
        let channelStr: String
        if let wlanChannel = interface.wlanChannel() {
            let band: String
            switch wlanChannel.channelBand {
            case .bandUnknown: band = "unknown"
            case .band2GHz: band = "2GHz"
            case .band5GHz: band = "5GHz"
            case .band6GHz: band = "6GHz"
            @unknown default: band = "unknown"
            }
            channelStr = "\(wlanChannel.channelNumber) (\(band))"
        } else {
            channelStr = "N/A"
        }
        return WiFiSnapshot(
            ssid: ssidValue, rssi: rssiValue,
            noise: noiseValue, channel: channelStr)
    }

    // MARK: — CWEventDelegate (called on CoreWLAN's own queue)

    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in self.refreshWiFiInfo() }
    }

    nonisolated func bssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in self.refreshWiFiInfo() }
    }

    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in self.refreshWiFiInfo() }
    }

    nonisolated func linkQualityDidChangeForWiFiInterface(
        withName interfaceName: String, rssi: Int, transmitRate: Double
    ) {
        // Avoid an IPC round-trip for RSSI updates — the value is given.
        Task { @MainActor in
            if self.rssi != rssi { self.rssi = rssi }
        }
    }

    nonisolated func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in self.refreshWiFiInfo() }
    }

    // MARK: — CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        // SSID is only readable once location access is granted.
        Task { @MainActor in self.refreshWiFiInfo() }
    }
}
