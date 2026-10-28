import SwiftUI

/// Widget for executing custom commands (waybar/eww style).
struct CustomCommandWidget: View {
    @EnvironmentObject var configProvider: ConfigProvider
    var config: ConfigData { configProvider.config }

    @State private var output: String = ""
    @State private var error: String?

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

    /// Restarts the polling loop whenever the command or interval changes.
    private struct TaskKey: Equatable {
        let command: String?
        let interval: Double
    }

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
        // The loop runs one command at a time, so a slow command can never
        // pile up background work; it is cancelled when the view disappears.
        .task(id: TaskKey(command: command, interval: interval)) {
            while !Task.isCancelled {
                await executeCommand()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        .onTapGesture {
            if let clickCmd = clickCommand {
                Task {
                    await SubprocessRunner.run(
                        executable: "/bin/bash", arguments: ["-c", clickCmd],
                        timeout: 5.0)
                }
            }
        }
    }

    private func executeCommand() async {
        guard let cmd = command else {
            error = "No command specified"
            return
        }
        let timeout = min(max(1.0, interval / 2.0), 5.0)
        let result = await SubprocessRunner.run(
            executable: "/bin/bash", arguments: ["-c", cmd], timeout: timeout)
        guard let result else {
            error = "Failed to launch command"
            output = ""
            return
        }
        if result.timedOut {
            error = "Command timed out after \(Int(timeout))s"
            output = ""
            return
        }
        let stdout = String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: result.stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if result.exitCode != 0 {
            error = stderr.isEmpty
                ? "Command failed with exit code \(result.exitCode)"
                : stderr
            output = ""
        } else {
            output = formatOutput(stdout)
            error = nil
        }
    }

    private func formatOutput(_ output: String) -> String {
        guard let format = format else {
            return output
        }
        return format.replacingOccurrences(of: "{output}", with: output)
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
