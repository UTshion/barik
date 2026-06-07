import CoreLocation
import CoreWLAN
import Network
import SwiftUI

enum NetworkState: String {
    case connected = "Connected"
    case connectedWithoutInternet = "No Internet"
    case connecting = "Connecting"
    case disconnected = "Disconnected"
    case disabled = "Disabled"
    case notSupported = "Not Supported"
}

enum WifiSignalStrength: String {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case unknown = "Unknown"
}

/// Unified view model for monitoring network and Wi‑Fi status.
///
/// Event-driven:
/// - Overall reachability via `NWPathMonitor` (always was event-driven; unchanged).
/// - Wi‑Fi details (SSID/RSSI/channel) via `CWEventDelegate` — replaces the previous
///   main-runloop 5s polling that could stall when wifid was slow.
final class NetworkStatusViewModel: NSObject, ObservableObject,
    CLLocationManagerDelegate, CWEventDelegate
{

    @Published var wifiState: NetworkState = .disconnected
    @Published var ethernetState: NetworkState = .disconnected

    @Published var ssid: String = "Not connected"
    @Published var rssi: Int = 0
    @Published var noise: Int = 0
    @Published var channel: String = "N/A"

    var wifiSignalStrength: WifiSignalStrength {
        if ssid == "Not connected" || ssid == "No interface" {
            return .unknown
        }
        if rssi >= -50 { return .high }
        if rssi >= -70 { return .medium }
        return .low
    }

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "NetworkMonitor")

    private let wifiClient = CWWiFiClient.shared()
    private let wifiQueue = DispatchQueue(label: "app.barik.coreWLAN")
    private var safetyTimer: Timer?

    private let locationManager = CLLocationManager()

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.requestWhenInUseAuthorization()
        startNetworkMonitoring()
        startWiFiMonitoring()
    }

    deinit {
        stopNetworkMonitoring()
        stopWiFiMonitoring()
    }

    // MARK: — NWPathMonitor for overall network status.

    private func startNetworkMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if path.availableInterfaces.contains(where: { $0.type == .wifi }) {
                    if path.usesInterfaceType(.wifi) {
                        switch path.status {
                        case .satisfied:
                            self.wifiState = .connected
                        case .requiresConnection:
                            self.wifiState = .connecting
                        default:
                            self.wifiState = .connectedWithoutInternet
                        }
                    } else {
                        self.wifiState = .disconnected
                    }
                } else {
                    self.wifiState = .notSupported
                }

                if path.availableInterfaces.contains(where: {
                    $0.type == .wiredEthernet
                }) {
                    if path.usesInterfaceType(.wiredEthernet) {
                        switch path.status {
                        case .satisfied:
                            self.ethernetState = .connected
                        case .requiresConnection:
                            self.ethernetState = .connecting
                        default:
                            self.ethernetState = .disconnected
                        }
                    } else {
                        self.ethernetState = .disconnected
                    }
                } else {
                    self.ethernetState = .notSupported
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }

    private func stopNetworkMonitoring() {
        monitor.cancel()
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
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) {
            [weak self] _ in
            self?.refreshWiFiInfo()
        }
        refreshWiFiInfo()
    }

    private func stopWiFiMonitoring() {
        safetyTimer?.invalidate()
        safetyTimer = nil
        for event in [
            CWEventType.ssidDidChange, .bssidDidChange, .linkDidChange,
            .linkQualityDidChange, .powerDidChange
        ] {
            try? wifiClient.stopMonitoringEvent(with: event)
        }
        wifiClient.delegate = nil
    }

    /// Reads CoreWLAN off the main thread and posts back to main.
    private func refreshWiFiInfo() {
        wifiQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.readSnapshot()
            DispatchQueue.main.async {
                self.ssid = snapshot.ssid
                self.rssi = snapshot.rssi
                self.noise = snapshot.noise
                self.channel = snapshot.channel
            }
        }
    }

    private struct WiFiSnapshot {
        let ssid: String
        let rssi: Int
        let noise: Int
        let channel: String
    }

    private func readSnapshot() -> WiFiSnapshot {
        guard let interface = wifiClient.interface() else {
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

    // MARK: — CWEventDelegate

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        refreshWiFiInfo()
    }

    func bssidDidChangeForWiFiInterface(withName interfaceName: String) {
        refreshWiFiInfo()
    }

    func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        refreshWiFiInfo()
    }

    func linkQualityDidChangeForWiFiInterface(
        withName interfaceName: String, rssi: Int, transmitRate: Double
    ) {
        // Avoid an IPC round-trip for RSSI updates — the value is given.
        DispatchQueue.main.async {
            self.rssi = rssi
        }
    }

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        refreshWiFiInfo()
    }

    // MARK: — CLLocationManagerDelegate.

    func locationManager(
        _ manager: CLLocationManager,
        didChangeAuthorization status: CLAuthorizationStatus
    ) {
        refreshWiFiInfo()
    }
}
