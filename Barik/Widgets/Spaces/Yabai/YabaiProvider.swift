import Foundation

class YabaiSpacesProvider: SpacesProvider, SwitchableSpacesProvider {
    typealias SpaceType = YabaiSpace
    let executablePath = ConfigManager.shared.config.yabai.path

    private static let timeout: TimeInterval = 3.0

    private func runYabaiCommand(arguments: [String]) -> Data? {
        guard
            let result = SubprocessRunner.run(
                executable: executablePath,
                arguments: arguments,
                timeout: Self.timeout)
        else {
            return nil
        }
        if result.timedOut || result.exitCode != 0 {
            return nil
        }
        return result.stdout
    }

    private func fetchSpaces() -> [YabaiSpace]? {
        guard
            let data = runYabaiCommand(arguments: ["-m", "query", "--spaces"])
        else {
            return nil
        }
        do {
            return try JSONDecoder().decode([YabaiSpace].self, from: data)
        } catch {
            print("Decode yabai spaces error: \(error)")
            return nil
        }
    }

    private func fetchWindows() -> [YabaiWindow]? {
        guard
            let data = runYabaiCommand(arguments: ["-m", "query", "--windows"])
        else {
            return nil
        }
        do {
            return try JSONDecoder().decode([YabaiWindow].self, from: data)
        } catch {
            print("Decode yabai windows error: \(error)")
            return nil
        }
    }

    func getSpacesWithWindows() -> [YabaiSpace]? {
        guard let spaces = fetchSpaces(), let windows = fetchWindows() else {
            return nil
        }
        let filteredWindows = windows.filter {
            !($0.isHidden || $0.isFloating || $0.isSticky)
        }
        var spaceDict = Dictionary(
            uniqueKeysWithValues: spaces.map { ($0.id, $0) })
        for window in filteredWindows {
            if var space = spaceDict[window.spaceId] {
                space.windows.append(window)
                spaceDict[window.spaceId] = space
            }
        }
        var resultSpaces = Array(spaceDict.values)
        for i in 0..<resultSpaces.count {
            resultSpaces[i].windows.sort { $0.stackIndex < $1.stackIndex }
        }
        return resultSpaces.filter { !$0.windows.isEmpty }
    }

    func focusSpace(spaceId: String, needWindowFocus: Bool) {
        _ = runYabaiCommand(arguments: ["-m", "space", "--focus", spaceId])
        if !needWindowFocus { return }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + 0.1
        ) {
            if let spaces = self.getSpacesWithWindows() {
                if let space = spaces.first(where: { $0.id == Int(spaceId) }) {
                    let hasFocused = space.windows.contains { $0.isFocused }
                    if !hasFocused, let firstWindow = space.windows.first {
                        _ = self.runYabaiCommand(arguments: [
                            "-m", "window", "--focus", String(firstWindow.id),
                        ])
                    }
                }
            }
        }
    }

    func focusWindow(windowId: String) {
        _ = runYabaiCommand(arguments: ["-m", "window", "--focus", windowId])
    }
}
