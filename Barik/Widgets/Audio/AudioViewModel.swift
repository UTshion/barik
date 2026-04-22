import AppKit
import Foundation

/// View model for monitoring and controlling audio input/output devices.
class AudioViewModel: ObservableObject {
    @Published var outputVolume: Float = 0.0
    @Published var inputVolume: Float = 0.0
    @Published var outputDevices: [AudioDevice] = []
    @Published var inputDevices: [AudioDevice] = []
    @Published var selectedOutputDevice: AudioDevice?
    @Published var selectedInputDevice: AudioDevice?
    @Published var isMuted: Bool = false

    private var timer: Timer?

    init() {
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    private func startMonitoring() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// Fetches volume and device info on a background thread, then updates published properties on main.
    private func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let outputVol = self.fetchOutputVolume()
            let inputVol = self.fetchInputVolume()
            let (outputs, inputs) = self.fetchAudioDevices()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let vol = outputVol {
                    self.outputVolume = vol
                    self.isMuted = vol == 0
                }
                if let vol = inputVol {
                    self.inputVolume = vol
                }
                self.outputDevices = outputs
                self.inputDevices = inputs

                if self.selectedOutputDevice == nil
                    || !outputs.contains(where: { $0.id == self.selectedOutputDevice?.id }) {
                    self.selectedOutputDevice = outputs.first
                }
                if self.selectedInputDevice == nil
                    || !inputs.contains(where: { $0.id == self.selectedInputDevice?.id }) {
                    self.selectedInputDevice = inputs.first
                }
            }
        }
    }

    private func fetchOutputVolume() -> Float? {
        guard let str = runAppleScript("output volume of (get volume settings)"),
              let vol = Int(str) else { return nil }
        return Float(vol) / 100.0
    }

    private func fetchInputVolume() -> Float? {
        guard let str = runAppleScript("input volume of (get volume settings)"),
              let vol = Int(str) else { return nil }
        return Float(vol) / 100.0
    }

    /// Fetches all output and input audio devices in a single system_profiler call.
    private func fetchAudioDevices() -> (outputs: [AudioDevice], inputs: [AudioDevice]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPAudioDataType", "-json"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (
                [AudioDevice(id: "default", name: "Default Output", type: .output)],
                [AudioDevice(id: "default", name: "Default Input", type: .input)]
            )
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["SPAudioDataType"] as? [[String: Any]] else {
            return ([], [])
        }

        var outputs: [AudioDevice] = []
        var inputs: [AudioDevice] = []

        for item in items {
            guard let name = item["_name"] as? String else { continue }
            let coreAudio = item["coreaudio_key"] as? String ?? ""
            let deviceType = item["_type"] as? String ?? ""
            let deviceId = coreAudio.isEmpty ? name : coreAudio

            if coreAudio.lowercased().contains("output")
                || item["default_output_device"] != nil
                || deviceType.lowercased().contains("output")
                || deviceType.lowercased().contains("speaker")
                || deviceType.lowercased().contains("headphone") {
                outputs.append(AudioDevice(id: deviceId, name: name, type: .output))
            }
            if coreAudio.lowercased().contains("input")
                || item["default_input_device"] != nil
                || deviceType.lowercased().contains("input")
                || deviceType.lowercased().contains("microphone")
                || deviceType.lowercased().contains("mic") {
                inputs.append(AudioDevice(id: deviceId, name: name, type: .input))
            }
        }

        return (outputs, inputs)
    }

    /// Executes an AppleScript via osascript subprocess (thread-safe, can be called from any thread).
    @discardableResult
    private func runAppleScript(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            if let data = script.data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(data)
            }
            inputPipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.flatMap { $0.isEmpty ? nil : $0 }
    }

    func setOutputVolume(_ volume: Float) {
        let clampedVolume = max(0.0, min(1.0, volume))
        let volumePercent = Int(clampedVolume * 100)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runAppleScript("set volume output volume \(volumePercent)")
            DispatchQueue.main.async { [weak self] in
                self?.outputVolume = clampedVolume
                self?.isMuted = clampedVolume == 0
            }
        }
    }

    func setInputVolume(_ volume: Float) {
        let volumePercent = Int(volume * 100)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runAppleScript("set volume input volume \(volumePercent)")
            DispatchQueue.main.async { [weak self] in
                self?.inputVolume = volume
            }
        }
    }

    func selectOutputDevice(_ device: AudioDevice) {
        openSystemSoundPreferences()
        selectedOutputDevice = device
    }

    func selectInputDevice(_ device: AudioDevice) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.sound?Input") {
            NSWorkspace.shared.open(url)
        }
        selectedInputDevice = device
    }

    func toggleMute() {
        isMuted.toggle()
        setOutputVolume(isMuted ? 0.0 : outputVolume)
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
}

enum AudioDeviceType {
    case input
    case output
}
