import Foundation
import os

nonisolated final class YabaiSpacesProvider: SpacesProvider {
    private let executablePath: String
    private static let timeout: TimeInterval = 3.0
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.barik",
        category: "YabaiProvider")

    init(executablePath: String) {
        self.executablePath = executablePath
    }

    @concurrent func getSpacesWithWindows() async -> [AnySpace]? {
        await fetchSpacesWithWindows()?.map { AnySpace($0) }
    }

    @concurrent func focusSpace(spaceId: String, needWindowFocus: Bool) async {
        _ = await run(["-m", "space", "--focus", spaceId])
        guard needWindowFocus else { return }

        // Give yabai a moment to settle, then focus the first window if the
        // space came up without a focused one.
        try? await Task.sleep(for: .milliseconds(100))
        guard
            let space = await fetchSpacesWithWindows()?.first(where: {
                $0.id == Int(spaceId)
            }),
            !space.windows.contains(where: \.isFocused),
            let firstWindow = space.windows.first
        else { return }
        _ = await run(["-m", "window", "--focus", String(firstWindow.id)])
    }

    @concurrent func focusWindow(windowId: String) async {
        _ = await run(["-m", "window", "--focus", windowId])
    }

    private func fetchSpacesWithWindows() async -> [YabaiSpace]? {
        async let spacesTask: [YabaiSpace]? = decode(
            ["-m", "query", "--spaces"])
        async let windowsTask: [YabaiWindow]? = decode(
            ["-m", "query", "--windows"])
        guard let spaces = await spacesTask, let windows = await windowsTask
        else { return nil }

        var spaceDict = Dictionary(
            spaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for window in windows
        where !(window.isHidden || window.isFloating || window.isSticky) {
            spaceDict[window.spaceId]?.windows.append(window)
        }
        return spaceDict.values
            .filter { !$0.windows.isEmpty }
            .map { space in
                var space = space
                space.windows.sort { $0.stackIndex < $1.stackIndex }
                return space
            }
    }

    private func run(_ arguments: [String]) async -> Data? {
        guard
            let result = await SubprocessRunner.run(
                executable: executablePath, arguments: arguments,
                timeout: Self.timeout),
            !result.timedOut, result.exitCode == 0
        else { return nil }
        return result.stdout
    }

    private func decode<T: Decodable>(_ arguments: [String]) async -> T? {
        // Empty output means "nothing matched" (e.g. no focused window).
        guard let data = await run(arguments), !data.isEmpty else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Self.logger.error(
                "Decode error for \(arguments.joined(separator: " "), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
