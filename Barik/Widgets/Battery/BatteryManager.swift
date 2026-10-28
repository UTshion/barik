import Foundation
import IOKit.ps
import Observation

/// Monitors battery status via IOKit power-source notifications.
/// Event-driven — `IOPSNotificationCreateRunLoopSource` posts on the main runloop
/// when the system's power state changes (charger plug/unplug, capacity change, etc.).
/// A coarse safety-net tick (60s) is the only remaining polling.
///
/// Shared by every bar and popup so there is a single IOKit observer for the
/// whole app instead of one per widget instance.
@MainActor
@Observable
final class BatteryManager {
    static let shared = BatteryManager()

    private(set) var batteryLevel: Int = 0
    private(set) var isCharging: Bool = false
    private(set) var isPluggedIn: Bool = false

    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var safetyTask: Task<Void, Never>?

    private init() {
        updateBatteryStatus()
        installPowerSourceObserver()

        safetyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.updateBatteryStatus()
            }
        }
    }

    private func installPowerSourceObserver() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            // The source is attached to the main runloop, so the callback
            // always fires on the main thread.
            MainActor.assumeIsolated {
                Unmanaged<BatteryManager>.fromOpaque(context)
                    .takeUnretainedValue()
                    .updateBatteryStatus()
            }
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
            guard
                let description = IOPSGetPowerSourceDescription(
                    snapshot, source)?.takeUnretainedValue() as? [String: Any],
                let currentCapacity = description[
                    kIOPSCurrentCapacityKey as String] as? Int,
                let maxCapacity = description[kIOPSMaxCapacityKey as String]
                    as? Int,
                let charging = description[kIOPSIsChargingKey as String]
                    as? Bool,
                let powerSourceState = description[
                    kIOPSPowerSourceStateKey as String] as? String
            else { continue }

            let isAC = powerSourceState == kIOPSACPowerValue
            let level =
                maxCapacity > 0 ? (currentCapacity * 100) / maxCapacity : 0

            // Only write on change so observers aren't invalidated needlessly.
            if batteryLevel != level { batteryLevel = level }
            if isCharging != charging { isCharging = charging }
            if isPluggedIn != isAC { isPluggedIn = isAC }
        }
    }
}
