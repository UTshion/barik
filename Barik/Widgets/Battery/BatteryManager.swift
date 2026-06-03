import Foundation
import IOKit.ps

/// Monitors battery status via IOKit power-source notifications.
/// Event-driven — `IOPSNotificationCreateRunLoopSource` posts on the main runloop
/// when the system's power state changes (charger plug/unplug, capacity change, etc.).
/// A coarse safety-net timer (60s) is the only remaining polling.
class BatteryManager: ObservableObject {
    @Published var batteryLevel: Int = 0
    @Published var isCharging: Bool = false
    @Published var isPluggedIn: Bool = false

    private var runLoopSource: CFRunLoopSource?
    private var safetyTimer: Timer?

    init() {
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    private func startMonitoring() {
        updateBatteryStatus()
        installPowerSourceObserver()

        safetyTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) {
            [weak self] _ in
            self?.updateBatteryStatus()
        }
    }

    private func stopMonitoring() {
        safetyTimer?.invalidate()
        safetyTimer = nil
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = nil
        }
    }

    private func installPowerSourceObserver() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let manager = Unmanaged<BatteryManager>.fromOpaque(context)
                .takeUnretainedValue()
            // Callback fires on the runloop the source is attached to (main).
            manager.updateBatteryStatus()
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?
            .takeRetainedValue()
        {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
    }

    /// Updates the battery level and charging state.
    func updateBatteryStatus() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(snapshot)?
                .takeRetainedValue() as? [CFTypeRef]
        else {
            return
        }

        for source in sources {
            if let description = IOPSGetPowerSourceDescription(
                snapshot, source)?.takeUnretainedValue() as? [String: Any],
                let currentCapacity = description[
                    kIOPSCurrentCapacityKey as String] as? Int,
                let maxCapacity = description[kIOPSMaxCapacityKey as String]
                    as? Int,
                let charging = description[kIOPSIsChargingKey as String]
                    as? Bool,
                let powerSourceState = description[
                    kIOPSPowerSourceStateKey as String] as? String
            {
                let isAC = (powerSourceState == kIOPSACPowerValue)
                let level = maxCapacity > 0
                    ? (currentCapacity * 100) / maxCapacity : 0

                let publish = { [weak self] in
                    guard let self else { return }
                    self.batteryLevel = level
                    self.isCharging = charging
                    self.isPluggedIn = isAC
                }
                if Thread.isMainThread {
                    publish()
                } else {
                    DispatchQueue.main.async(execute: publish)
                }
            }
        }
    }
}
