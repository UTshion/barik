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
        let raw: Double
        switch config["interval"] {
        case .some(.double(let d)): raw = d
        case .some(.int(let i)): raw = Double(i)
        default: raw = 5.0
        }
        // Floor to 1s so a typo can't turn this into a fork-bomb.
        return max(1.0, raw)
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
        // Re-entrancy guard: skip the tick if the previous command is still running.
        // Prevents a slow user command from queueing background work indefinitely.
        guard !isRunning else { return }

        isRunning = true
        let timeout = min(max(1.0, interval / 2.0), 5.0)
        DispatchQueue.global(qos: .utility).async {
            let result = SubprocessRunner.run(
                executable: "/bin/bash",
                arguments: ["-c", cmd],
                timeout: timeout)
            DispatchQueue.main.async {
                defer { isRunning = false }
                guard let result else {
                    self.error = "Failed to launch command"
                    self.output = ""
                    return
                }
                if result.timedOut {
                    self.error = "Command timed out after \(Int(timeout))s"
                    self.output = ""
                    return
                }
                let stdout = String(data: result.stdout, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let stderr = String(data: result.stderr, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if result.exitCode != 0 {
                    self.error = stderr.isEmpty
                        ? "Command failed with exit code \(result.exitCode)"
                        : stderr
                    self.output = ""
                } else {
                    self.output = formatOutput(stdout)
                    self.error = nil
                }
            }
        }
    }

    private func executeClickCommand(_ cmd: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = SubprocessRunner.run(
                executable: "/bin/bash",
                arguments: ["-c", cmd],
                timeout: 5.0)
        }
    }

    private func formatOutput(_ output: String) -> String {
        guard let format = format else {
            return output
        }
        return format.replacingOccurrences(of: "{output}", with: output)
    }

    private func startTimer() {
        let tickInterval = interval
        guard tickInterval > 0 else { return }

        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { _ in
            executeCommand()
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
