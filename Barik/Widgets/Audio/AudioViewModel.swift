import AppKit
import CoreAudio
import Foundation

/// View model for monitoring and controlling audio input/output devices.
///
/// All queries and mutations go through the Core Audio HAL — no subprocesses.
/// Updates are pushed via Core Audio property listeners, with a coarse safety-net
/// timer (30s) only to catch missed events.
class AudioViewModel: ObservableObject {
    @Published var outputVolume: Float = 0.0
    @Published var inputVolume: Float = 0.0
    @Published var outputDevices: [AudioDevice] = []
    @Published var inputDevices: [AudioDevice] = []
    @Published var selectedOutputDevice: AudioDevice?
    @Published var selectedInputDevice: AudioDevice?
    @Published var isMuted: Bool = false

    private var globalListeners = CoreAudioListenerToken()
    private var outputDeviceListeners = CoreAudioListenerToken()
    private var inputDeviceListeners = CoreAudioListenerToken()
    private var currentOutputDeviceID: AudioObjectID?
    private var currentInputDeviceID: AudioObjectID?

    private var safetyTimer: Timer?

    init() {
        refreshAll()
        installGlobalListeners()
        // Safety net: cheap, only invokes property reads — no subprocesses.
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.refreshAll()
        }
    }

    deinit {
        safetyTimer?.invalidate()
        globalListeners.removeAll()
        outputDeviceListeners.removeAll()
        inputDeviceListeners.removeAll()
    }

    // MARK: - Listener setup

    private func installGlobalListeners() {
        // Device list changes (USB plug/unplug, AirPods connect, etc.).
        globalListeners.add(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        ) { [weak self] in
            DispatchQueue.main.async { self?.refreshDeviceList() }
        }
        // Default output device changed (user picked a new device elsewhere).
        globalListeners.add(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice
        ) { [weak self] in
            DispatchQueue.main.async { self?.refreshOutput() }
        }
        // Default input device changed.
        globalListeners.add(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultInputDevice
        ) { [weak self] in
            DispatchQueue.main.async { self?.refreshInput() }
        }
    }

    /// Re-targets the volume/mute listeners to the currently-default output device.
    private func attachOutputDeviceListeners(_ deviceID: AudioObjectID) {
        outputDeviceListeners.removeAll()
        outputDeviceListeners.add(
            objectID: deviceID,
            selector: kVirtualMainVolumeSelector,
            scope: kAudioDevicePropertyScopeOutput
        ) { [weak self] in
            DispatchQueue.main.async { self?.refreshOutputVolumeAndMute() }
        }
        outputDeviceListeners.add(
            objectID: deviceID,
            selector: kAudioDevicePropertyMute,
            scope: kAudioDevicePropertyScopeOutput
        ) { [weak self] in
            DispatchQueue.main.async { self?.refreshOutputVolumeAndMute() }
        }
    }

    private func attachInputDeviceListeners(_ deviceID: AudioObjectID) {
        inputDeviceListeners.removeAll()
        inputDeviceListeners.add(
            objectID: deviceID,
            selector: kVirtualMainVolumeSelector,
            scope: kAudioDevicePropertyScopeInput
        ) { [weak self] in
            DispatchQueue.main.async { self?.refreshInputVolume() }
        }
    }

    // MARK: - Refresh routines (all run on main)

    private func refreshAll() {
        refreshDeviceList()
        refreshOutput()
        refreshInput()
    }

    private func refreshDeviceList() {
        let ids = CoreAudioHelpers.allDeviceIDs()
        var outputs: [AudioDevice] = []
        var inputs: [AudioDevice] = []
        for id in ids {
            let name = CoreAudioHelpers.deviceName(id) ?? "Unknown"
            let uid = CoreAudioHelpers.deviceUID(id) ?? "id-\(id)"
            if CoreAudioHelpers.deviceHasStreams(id, scope: .output) {
                outputs.append(
                    AudioDevice(
                        id: uid, name: name, type: .output,
                        audioObjectID: id))
            }
            if CoreAudioHelpers.deviceHasStreams(id, scope: .input) {
                inputs.append(
                    AudioDevice(
                        id: uid, name: name, type: .input,
                        audioObjectID: id))
            }
        }
        outputs.sort { $0.name < $1.name }
        inputs.sort { $0.name < $1.name }
        self.outputDevices = outputs
        self.inputDevices = inputs

        // Ensure the selected device still exists.
        if let selectedOutputDevice,
           !outputs.contains(where: { $0.id == selectedOutputDevice.id }) {
            self.selectedOutputDevice = outputs.first(where: {
                $0.audioObjectID == currentOutputDeviceID
            }) ?? outputs.first
        }
        if let selectedInputDevice,
           !inputs.contains(where: { $0.id == selectedInputDevice.id }) {
            self.selectedInputDevice = inputs.first(where: {
                $0.audioObjectID == currentInputDeviceID
            }) ?? inputs.first
        }
    }

    private func refreshOutput() {
        guard let deviceID = CoreAudioHelpers.defaultDevice(scope: .output) else {
            currentOutputDeviceID = nil
            return
        }
        currentOutputDeviceID = deviceID
        attachOutputDeviceListeners(deviceID)
        refreshOutputVolumeAndMute()
        self.selectedOutputDevice = outputDevices.first(where: {
            $0.audioObjectID == deviceID
        })
    }

    private func refreshInput() {
        guard let deviceID = CoreAudioHelpers.defaultDevice(scope: .input) else {
            currentInputDeviceID = nil
            return
        }
        currentInputDeviceID = deviceID
        attachInputDeviceListeners(deviceID)
        refreshInputVolume()
        self.selectedInputDevice = inputDevices.first(where: {
            $0.audioObjectID == deviceID
        })
    }

    private func refreshOutputVolumeAndMute() {
        guard let id = currentOutputDeviceID else { return }
        let vol = CoreAudioHelpers.volume(id, scope: .output) ?? 0
        let muted = CoreAudioHelpers.isMuted(id, scope: .output)
        self.outputVolume = vol
        self.isMuted = muted || vol == 0
    }

    private func refreshInputVolume() {
        guard let id = currentInputDeviceID else { return }
        self.inputVolume = CoreAudioHelpers.volume(id, scope: .input) ?? 0
    }

    // MARK: - Public mutations

    func setOutputVolume(_ volume: Float) {
        let clamped = max(0, min(1, volume))
        // Optimistic UI update — the property listener will reconcile if needed.
        self.outputVolume = clamped
        self.isMuted = clamped == 0
        guard let id = currentOutputDeviceID else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            CoreAudioHelpers.setVolume(clamped, deviceID: id, scope: .output)
        }
    }

    func setInputVolume(_ volume: Float) {
        let clamped = max(0, min(1, volume))
        self.inputVolume = clamped
        guard let id = currentInputDeviceID else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            CoreAudioHelpers.setVolume(clamped, deviceID: id, scope: .input)
        }
    }

    func selectOutputDevice(_ device: AudioDevice) {
        selectedOutputDevice = device
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let success = CoreAudioHelpers.setDefaultDevice(
                device.audioObjectID, scope: .output)
            DispatchQueue.main.async {
                if !success {
                    self?.openSystemSoundPreferences()
                }
            }
        }
    }

    func selectInputDevice(_ device: AudioDevice) {
        selectedInputDevice = device
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let success = CoreAudioHelpers.setDefaultDevice(
                device.audioObjectID, scope: .input)
            DispatchQueue.main.async {
                if !success {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.sound?Input") {
                        NSWorkspace.shared.open(url)
                    }
                    _ = self  // silence unused-capture warning
                }
            }
        }
    }

    func toggleMute() {
        let newMuted = !isMuted
        isMuted = newMuted
        guard let id = currentOutputDeviceID else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            // Try the hardware mute first; if the device doesn't support it,
            // fall back to setting volume to 0 / restoring it.
            if !CoreAudioHelpers.setMuted(newMuted, deviceID: id, scope: .output) {
                let target: Float = newMuted ? 0.0 : 0.5
                CoreAudioHelpers.setVolume(target, deviceID: id, scope: .output)
            }
        }
    }

    func openSystemSoundPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.sound?Output") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct AudioDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let type: AudioDeviceType
    let audioObjectID: AudioObjectID
}

enum AudioDeviceType {
    case input
    case output
}
