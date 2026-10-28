import Foundation
import os

nonisolated final class AerospaceSpacesProvider: SpacesProvider {
    private let executablePath: String
    private static let timeout: TimeInterval = 3.0
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.barik",
        category: "AerospaceProvider")

    init(executablePath: String) {
        self.executablePath = executablePath
    }

    @concurrent func getSpacesWithWindows() async -> [AnySpace]? {
        // The four queries are independent; run them concurrently so one
        // refresh costs roughly a single CLI round-trip.
        async let spacesTask: [AeroSpace]? = decode(
            ["list-workspaces", "--all", "--json"])
        async let windowsTask: [AeroWindow]? = decode([
            "list-windows", "--all", "--json", "--format",
            "%{window-id} %{app-name} %{window-title} %{workspace}",
        ])
        async let focusedSpaceTask: [AeroSpace]? = decode(
            ["list-workspaces", "--focused", "--json"])
        async let focusedWindowTask: [AeroWindow]? = decode(
            ["list-windows", "--focused", "--json"])

        guard var spaces = await spacesTask, let windows = await windowsTask
        else { return nil }
        let focusedSpace = await focusedSpaceTask?.first
        let focusedWindow = await focusedWindowTask?.first

        if let focusedSpace {
            for i in spaces.indices {
                spaces[i].isFocused = spaces[i].id == focusedSpace.id
            }
        }

        var spaceDict = Dictionary(
            spaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for var window in windows {
            window.isFocused = window.id == focusedWindow?.id
            // Windows without a workspace belong to the focused one.
            let key =
                (window.workspace?.isEmpty == false
                    ? window.workspace : focusedSpace?.id) ?? ""
            spaceDict[key]?.windows.append(window)
        }

        return spaceDict.values
            .filter { !$0.windows.isEmpty }
            .map { space in
                var space = space
                space.windows.sort { $0.id < $1.id }
                return AnySpace(space)
            }
    }

    @concurrent func focusSpace(spaceId: String, needWindowFocus: Bool) async {
        _ = await run(["workspace", spaceId])
    }

    @concurrent func focusWindow(windowId: String) async {
        // `focus --window-id` also switches to the window's workspace.
        _ = await run(["focus", "--window-id", windowId])
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
