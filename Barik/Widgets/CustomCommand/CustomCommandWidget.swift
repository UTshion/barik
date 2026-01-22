import SwiftUI

/// Widget for executing custom commands (waybar/eww style).
struct CustomCommandWidget: View {
    @EnvironmentObject var configProvider: ConfigProvider
    var config: ConfigData { configProvider.config }
    
    @State private var output: String = ""
    @State private var error: String?
    @State private var isRunning: Bool = false
    @State private var timer: Timer?
    
    var command: String? { config["command"]?.stringValue }
    var interval: Double {
        let intervalValue = config["interval"]?.doubleValue ?? config["interval"]?.intValue
        return intervalValue.map { Double($0) } ?? 5.0
    }
    var format: String? { config["format"]?.stringValue }
    var clickCommand: String? { config["click-command"]?.stringValue }
    
    var body: some View {
        Group {
            if let error = error {
                Text("Error: \(error)")
                    .foregroundColor(.red)
                    .font(.system(size: 11))
            } else if !output.isEmpty {
                Text(output)
                    .foregroundColor(.foregroundOutside)
                    .font(.system(size: 11))
            } else {
                Text("...")
                    .foregroundColor(.foregroundOutside.opacity(0.5))
                    .font(.system(size: 11))
            }
        }
        .onAppear {
            executeCommand()
            startTimer()
        }
        .onDisappear {
            stopTimer()
        }
        .onTapGesture {
            if let clickCmd = clickCommand {
                executeClickCommand(clickCmd)
            }
        }
    }
    
    private func executeCommand() {
        guard let cmd = command else {
            error = "No command specified"
            return
        }
        
        isRunning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = executeShellCommand(cmd)
            DispatchQueue.main.async {
                if let output = result.output, !output.isEmpty {
                    self.output = formatOutput(output)
                    self.error = nil
                } else if let error = result.error {
                    self.error = error
                    self.output = ""
                }
                isRunning = false
            }
        }
    }
    
    private func executeClickCommand(_ cmd: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = executeShellCommand(cmd)
        }
    }
    
    private func executeShellCommand(_ command: String) -> (output: String?, error: String?) {
        let process = Process()
        process.launchPath = "/bin/bash"
        process.arguments = ["-c", command]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            
            let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let error = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if process.terminationStatus != 0 {
                return (nil, error ?? "Command failed with exit code \(process.terminationStatus)")
            }
            
            return (output, nil)
        } catch {
            return (nil, "Failed to execute command: \(error.localizedDescription)")
        }
    }
    
    private func formatOutput(_ output: String) -> String {
        guard let format = format else {
            return output
        }
        
        // Simple format replacement: {output} is replaced with the command output
        return format.replacingOccurrences(of: "{output}", with: output)
    }
    
    private func startTimer() {
        guard interval > 0 else { return }
        
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.executeCommand()
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

struct CustomCommandWidget_Previews: PreviewProvider {
    static var previews: some View {
        CustomCommandWidget()
            .frame(width: 200, height: 100)
            .background(Color.black)
            .environmentObject(ConfigProvider(config: [
                "command": TOMLValue.string("echo 'Hello'"),
                "interval": TOMLValue.int(5),
                "format": TOMLValue.string("{output}")
            ]))
    }
}
