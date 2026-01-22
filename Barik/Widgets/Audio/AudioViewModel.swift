import AppKit
import Combine
import Foundation
import SwiftUI

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
        updateAudioDevices()
        updateVolume()
        
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateVolume()
            self?.updateAudioDevices()
        }
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func updateVolume() {
        // Get output volume using AppleScript
        let outputScript = """
        output volume of (get volume settings)
        """
        
        if let appleScript = NSAppleScript(source: outputScript) {
            var error: NSDictionary?
            let result = appleScript.executeAndReturnError(&error)
            if error == nil, let volumeString = result.stringValue, let volume = Int(volumeString) {
                outputVolume = Float(volume) / 100.0
                isMuted = volume == 0
            } else {
                // Fallback to NSSound
                outputVolume = NSSound.systemVolume
            }
        } else {
            // Fallback to NSSound
            outputVolume = NSSound.systemVolume
        }
        
        // Get input volume using AppleScript
        let inputScript = """
        input volume of (get volume settings)
        """
        
        if let appleScript = NSAppleScript(source: inputScript) {
            var error: NSDictionary?
            let result = appleScript.executeAndReturnError(&error)
            if error == nil, let volumeString = result.stringValue, let volume = Int(volumeString) {
                inputVolume = Float(volume) / 100.0
            }
        }
    }

    private func updateAudioDevices() {
        // Get all available devices using system_profiler
        let allOutputs = getAllOutputDevices()
        let allInputs = getAllInputDevices()
        
        outputDevices = allOutputs
        inputDevices = allInputs
        
        // Update selected devices if not set
        if selectedOutputDevice == nil && !allOutputs.isEmpty {
            selectedOutputDevice = allOutputs.first
        } else if let currentOutput = selectedOutputDevice,
                  !allOutputs.contains(where: { $0.id == currentOutput.id }) {
            // Current device no longer available, select first
            selectedOutputDevice = allOutputs.first
        }
        
        if selectedInputDevice == nil && !allInputs.isEmpty {
            selectedInputDevice = allInputs.first
        } else if let currentInput = selectedInputDevice,
                   !allInputs.contains(where: { $0.id == currentInput.id }) {
            // Current device no longer available, select first
            selectedInputDevice = allInputs.first
        }
    }

    private func getDefaultOutputDevice() -> AudioDevice? {
        // Use system_profiler to get default output device
        let task = Process()
        task.launchPath = "/usr/sbin/system_profiler"
        task.arguments = ["SPAudioDataType", "-json"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = json["SPAudioDataType"] as? [[String: Any]] {
                for item in items {
                    if let name = item["_name"] as? String,
                       let coreAudio = item["coreaudio_key"] as? String,
                       coreAudio.contains("output") {
                        return AudioDevice(id: coreAudio, name: name, type: .output)
                    }
                }
            }
        } catch {
            // Fallback to a simple default
            return AudioDevice(id: "default", name: "Default Output", type: .output)
        }
        
        return nil
    }

    private func getDefaultInputDevice() -> AudioDevice? {
        // Similar to output device
        let task = Process()
        task.launchPath = "/usr/sbin/system_profiler"
        task.arguments = ["SPAudioDataType", "-json"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = json["SPAudioDataType"] as? [[String: Any]] {
                for item in items {
                    if let name = item["_name"] as? String,
                       let coreAudio = item["coreaudio_key"] as? String,
                       coreAudio.contains("input") {
                        return AudioDevice(id: coreAudio, name: name, type: .input)
                    }
                }
            }
        } catch {
            // Fallback
            return AudioDevice(id: "default", name: "Default Input", type: .input)
        }
        
        return nil
    }

    private func getAllOutputDevices() -> [AudioDevice] {
        var devices: [AudioDevice] = []
        
        // Use system_profiler to get all output devices
        let task = Process()
        task.launchPath = "/usr/sbin/system_profiler"
        task.arguments = ["SPAudioDataType", "-json"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = json["SPAudioDataType"] as? [[String: Any]] {
                for item in items {
                    if let name = item["_name"] as? String {
                        // Check device type from various fields
                        let coreAudio = item["coreaudio_key"] as? String ?? ""
                        let defaultOutput = item["default_output_device"] as? String
                        let deviceType = item["_type"] as? String ?? ""
                        
                        // Determine if it's an output device
                        let isOutput = coreAudio.lowercased().contains("output") ||
                                      defaultOutput != nil ||
                                      deviceType.lowercased().contains("output") ||
                                      deviceType.lowercased().contains("speaker") ||
                                      deviceType.lowercased().contains("headphone")
                        
                        if isOutput {
                            let deviceId = coreAudio.isEmpty ? name : coreAudio
                            devices.append(AudioDevice(id: deviceId, name: name, type: .output))
                        }
                    }
                }
            }
        } catch {
            // Fallback
            devices.append(AudioDevice(id: "default", name: "Default Output", type: .output))
        }
        
        return devices
    }

    private func getAllInputDevices() -> [AudioDevice] {
        var devices: [AudioDevice] = []
        
        // Use system_profiler to get all input devices
        let task = Process()
        task.launchPath = "/usr/sbin/system_profiler"
        task.arguments = ["SPAudioDataType", "-json"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = json["SPAudioDataType"] as? [[String: Any]] {
                for item in items {
                    if let name = item["_name"] as? String {
                        // Check device type from various fields
                        let coreAudio = item["coreaudio_key"] as? String ?? ""
                        let defaultInput = item["default_input_device"] as? String
                        let deviceType = item["_type"] as? String ?? ""
                        
                        // Determine if it's an input device
                        let isInput = coreAudio.lowercased().contains("input") ||
                                     defaultInput != nil ||
                                     deviceType.lowercased().contains("input") ||
                                     deviceType.lowercased().contains("microphone") ||
                                     deviceType.lowercased().contains("mic")
                        
                        if isInput {
                            let deviceId = coreAudio.isEmpty ? name : coreAudio
                            devices.append(AudioDevice(id: deviceId, name: name, type: .input))
                        }
                    }
                }
            }
        } catch {
            // Fallback
            devices.append(AudioDevice(id: "default", name: "Default Input", type: .input))
        }
        
        return devices
    }

    func setOutputVolume(_ volume: Float) {
        let clampedVolume = max(0.0, min(1.0, volume))
        let volumePercent = Int(clampedVolume * 100)
        
        let script = """
        set volume output volume \(volumePercent)
        """
        
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if error == nil {
                outputVolume = clampedVolume
                isMuted = clampedVolume == 0
            }
        } else {
            // Fallback
            NSSound.systemVolume = clampedVolume
            outputVolume = clampedVolume
            isMuted = clampedVolume == 0
        }
    }

    func setInputVolume(_ volume: Float) {
        // Input volume control requires CoreAudio or AppleScript
        // For now, we'll use AppleScript
        let script = """
        set volume input volume \(Int(volume * 100))
        """
        
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if error == nil {
                inputVolume = volume
            }
        }
    }

    func selectOutputDevice(_ device: AudioDevice) {
        // Note: Direct device switching via AppleScript is limited on macOS
        // We'll open System Preferences to the output tab
        // Users can then select the device manually
        openSystemSoundPreferences()
        selectedOutputDevice = device
    }

    func selectInputDevice(_ device: AudioDevice) {
        // Note: Direct device switching via AppleScript is limited on macOS
        // We'll open System Preferences to the input tab
        // Users can then select the device manually
        let script = """
        tell application "System Preferences"
            activate
            reveal anchor "input" of pane id "com.apple.preference.sound"
        end tell
        """
        
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
        
        selectedInputDevice = device
    }

    func toggleMute() {
        isMuted.toggle()
        let volume = isMuted ? 0.0 : outputVolume
        setOutputVolume(volume)
    }

    func openSystemSoundPreferences() {
        // Open System Preferences > Sound (output tab)
        // On macOS Ventura+, use System Settings instead
        if #available(macOS 13.0, *) {
            // macOS Ventura+ uses System Settings
            let script = """
            tell application "System Settings"
                activate
            end tell
            """
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
            }
            // Open via URL scheme
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.sound?Output") {
                NSWorkspace.shared.open(url)
            }
        } else {
            // macOS Monterey and earlier use System Preferences
            let script = """
            tell application "System Preferences"
                activate
                reveal anchor "output" of pane id "com.apple.preference.sound"
            end tell
            """
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
            }
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
