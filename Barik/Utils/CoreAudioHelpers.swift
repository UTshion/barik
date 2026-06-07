import CoreAudio
import Foundation

/// `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` (`'vmvc'`) — defined here
/// because the constant isn't bridged into Swift on modern SDKs even though the HAL
/// still services the selector. Provides a single virtual main volume control that
/// works on devices without a hardware master element (the common case).
let kVirtualMainVolumeSelector: AudioObjectPropertySelector =
    (UInt32(UInt8(ascii: "v")) << 24)
    | (UInt32(UInt8(ascii: "m")) << 16)
    | (UInt32(UInt8(ascii: "v")) << 8)
    | UInt32(UInt8(ascii: "c"))

/// Thin Swift wrappers over Core Audio HAL (AudioObjectGetPropertyData / SetPropertyData).
/// Replaces the previous `system_profiler` + `osascript` subprocess path that dominated
/// our subprocess load and could exhaust GCD's worker thread pool.
enum CoreAudioHelpers {

    enum Scope {
        case output, input

        var streamsScope: AudioObjectPropertyScope {
            switch self {
            case .output: return kAudioDevicePropertyScopeOutput
            case .input: return kAudioDevicePropertyScopeInput
            }
        }

        var defaultDeviceSelector: AudioObjectPropertySelector {
            switch self {
            case .output: return kAudioHardwarePropertyDefaultOutputDevice
            case .input: return kAudioHardwarePropertyDefaultInputDevice
            }
        }
    }

    // MARK: - Device enumeration

    /// Returns every device's AudioObjectID known to Core Audio.
    static func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            &dataSize, &ids)
        return status == noErr ? ids : []
    }

    /// True if the device has at least one stream in the given direction.
    static func deviceHasStreams(_ deviceID: AudioObjectID, scope: Scope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope.streamsScope,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID, &address, 0, nil, &dataSize)
        return status == noErr && dataSize > 0
    }

    /// Returns the device's human-readable name, e.g. "MacBook Pro Speakers".
    static func deviceName(_ deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(
                deviceID, &address, 0, nil, &dataSize, ptr)
        }
        return status == noErr ? (name as String) : nil
    }

    /// Returns the device's persistent unique identifier — survives reboots and
    /// reconnects, so it's the right thing to use as an `AudioDevice.id`.
    static func deviceUID(_ deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(
                deviceID, &address, 0, nil, &dataSize, ptr)
        }
        return status == noErr ? (uid as String) : nil
    }

    // MARK: - Default devices

    static func defaultDevice(scope: Scope) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: scope.defaultDeviceSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id: AudioObjectID = 0
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            &dataSize, &id)
        return status == noErr ? id : nil
    }

    @discardableResult
    static func setDefaultDevice(_ deviceID: AudioObjectID, scope: Scope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: scope.defaultDeviceSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &id)
        return status == noErr
    }

    // MARK: - Volume

    /// Reads the device's virtual main (master) volume in [0, 1].
    /// Falls back to channel 1's volume if the device has no main element.
    static func volume(_ deviceID: AudioObjectID, scope: Scope) -> Float? {
        let scopeAddr: AudioObjectPropertyScope =
            scope == .output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
        // Try the virtual main first.
        if let vol = readFloat(
            deviceID: deviceID,
            selector: kVirtualMainVolumeSelector,
            scope: scopeAddr, element: kAudioObjectPropertyElementMain)
        {
            return vol
        }
        // Some USB devices don't expose a main; try channel 1.
        return readFloat(
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: scopeAddr, element: 1)
    }

    @discardableResult
    static func setVolume(_ value: Float, deviceID: AudioObjectID, scope: Scope) -> Bool {
        let scopeAddr: AudioObjectPropertyScope =
            scope == .output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
        let clamped = max(0, min(1, value))
        if writeFloat(
            clamped, deviceID: deviceID,
            selector: kVirtualMainVolumeSelector,
            scope: scopeAddr, element: kAudioObjectPropertyElementMain)
        {
            return true
        }
        // Fall back to per-channel for devices without a main element.
        var anySet = false
        for channel: UInt32 in 1...2 {
            if writeFloat(
                clamped, deviceID: deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: scopeAddr, element: channel)
            {
                anySet = true
            }
        }
        return anySet
    }

    static func isMuted(_ deviceID: AudioObjectID, scope: Scope) -> Bool {
        let scopeAddr: AudioObjectPropertyScope =
            scope == .output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: scopeAddr,
            mElement: kAudioObjectPropertyElementMain)
        var muted: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &dataSize, &muted)
        return status == noErr && muted != 0
    }

    @discardableResult
    static func setMuted(_ muted: Bool, deviceID: AudioObjectID, scope: Scope) -> Bool {
        let scopeAddr: AudioObjectPropertyScope =
            scope == .output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: scopeAddr,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &value)
        return status == noErr
    }

    // MARK: - Private helpers

    private static func readFloat(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &dataSize, &value)
        return status == noErr ? Float(value) : nil
    }

    private static func writeFloat(
        _ value: Float,
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var value: Float32 = value
        let status = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil,
            UInt32(MemoryLayout<Float32>.size), &value)
        return status == noErr
    }
}

// MARK: - Property listener tracking

/// Owns a set of Core Audio property listeners and removes them on `deinit`.
/// Block-based variant — the same block reference must be passed to Add and Remove.
final class CoreAudioListenerToken {
    private struct Entry {
        let objectID: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private var entries: [Entry] = []
    private let queue: DispatchQueue?

    init(queue: DispatchQueue? = nil) {
        self.queue = queue
    }

    func add(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        handler: @escaping () -> Void
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: element)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            handler()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            objectID, &address, queue, block)
        if status == noErr {
            entries.append(Entry(objectID: objectID, address: address, block: block))
        }
    }

    func removeAll() {
        for entry in entries {
            var address = entry.address
            AudioObjectRemovePropertyListenerBlock(
                entry.objectID, &address, queue, entry.block)
        }
        entries.removeAll()
    }

    deinit {
        removeAll()
    }
}
