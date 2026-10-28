import Foundation
import Observation

/// Checks GitHub for newer Barik releases and installs them on request.
///
/// One shared instance serves the update banner on every display, so the
/// GitHub API is polled once per interval rather than once per bar.
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    private(set) var latestVersion: String?
    private(set) var updateAvailable = false

    /// Local path for the downloaded update directory.
    @ObservationIgnored private(set) var downloadedUpdatePath: String?
    /// URL for the update asset obtained from GitHub release JSON.
    @ObservationIgnored private var updateAssetURL: URL?

    private init() {
        // Check now and then every 30 minutes.
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchLatestRelease()
                try? await Task.sleep(for: .seconds(1800))
            }
        }
    }

    /// Returns a fallback download URL based on the version string.
    private func fallbackDownloadURL(for version: String) -> URL? {
        let versionWithoutPrefix =
            version.hasPrefix("v") ? String(version.dropFirst()) : version
        let urlString =
            "https://github.com/mocki-toki/barik/releases/download/\(version)/barik-v\(versionWithoutPrefix).zip"
        return URL(string: urlString)
    }

    nonisolated private struct Release: Decodable, Sendable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
        let tagName: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    /// Fetches the latest release information from GitHub and updates the state.
    func fetchLatestRelease() async {
        guard
            let url = URL(
                string:
                    "https://api.github.com/repos/mocki-toki/barik/releases/latest"
            )
        else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let release = try JSONDecoder().decode(Release.self, from: data)
            updateAssetURL =
                release.assets.first { $0.name.hasSuffix(".zip") }?
                .browserDownloadURL
            let currentVersion = VersionChecker.currentVersion ?? "0.0.0"
            latestVersion = release.tagName
            updateAvailable = compareVersion(release.tagName, currentVersion) > 0
        } catch {
            print("Error fetching release info: \(error)")
        }
    }

    /// Compares two version strings.
    /// - Returns: 1 if v1 > v2, -1 if v1 < v2, and 0 if equal.
    func compareVersion(_ v1: String, _ v2: String) -> Int {
        let version1 = v1.replacingOccurrences(of: "v", with: "")
        let version2 = v2.replacingOccurrences(of: "v", with: "")
        let parts1 = version1.split(separator: ".").compactMap { Int($0) }
        let parts2 = version2.split(separator: ".").compactMap { Int($0) }
        let maxCount = max(parts1.count, parts2.count)
        for i in 0..<maxCount {
            let num1 = i < parts1.count ? parts1[i] : 0
            let num2 = i < parts2.count ? parts2[i] : 0
            if num1 > num2 { return 1 }
            if num1 < num2 { return -1 }
        }
        return 0
    }

    /// Downloads and unzips the update archive.
    /// - Returns: The temporary directory URL containing the unzipped app.
    private func downloadAndUnzip(latest version: String) async -> URL? {
        guard
            let assetURL = updateAssetURL ?? fallbackDownloadURL(for: version)
        else {
            print("Invalid update URL")
            return nil
        }

        print("Downloading update from: \(assetURL.absoluteString)")
        do {
            let (localURL, response) = try await URLSession.shared.download(
                from: assetURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                print("Download failed with HTTP error")
                return nil
            }

            let fileManager = FileManager.default
            let tempDir = fileManager.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            try fileManager.createDirectory(
                at: tempDir, withIntermediateDirectories: true)
            let result = await SubprocessRunner.run(
                executable: "/usr/bin/unzip",
                arguments: ["-o", localURL.path, "-d", tempDir.path],
                timeout: 120)
            guard result?.exitCode == 0,
                fileManager.fileExists(
                    atPath: tempDir.appendingPathComponent("Barik.app").path)
            else {
                print("Unzipping failed: Barik.app not found in archive")
                return nil
            }
            return tempDir
        } catch {
            print("Update download error: \(error)")
            return nil
        }
    }

    /// Downloads and installs the update immediately.
    func downloadAndInstall(latest version: String) async {
        guard let tempDir = await downloadAndUnzip(latest: version) else {
            return
        }
        downloadedUpdatePath = tempDir.path
        installUpdate(latest: version)
    }

    /// Installs the update by replacing the current application.
    /// - Parameter version: The latest version string.
    func installUpdate(latest version: String) {
        guard let downloadedPath = downloadedUpdatePath else {
            print("No downloaded update to install")
            return
        }
        let newAppURL = URL(fileURLWithPath: downloadedPath)
            .appendingPathComponent("Barik.app")
        let destinationURL = URL(fileURLWithPath: "/Applications/Barik.app")
        let script = """
            #!/bin/bash
            sleep 2
            rm -rf "\(destinationURL.path)"
            mv "\(newAppURL.path)" "\(destinationURL.path)"
            open "\(destinationURL.path)"
            rm -- "$0"
            """

        let fileManager = FileManager.default
        let updateTempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try fileManager.createDirectory(
                at: updateTempDir, withIntermediateDirectories: true,
                attributes: nil)
            let scriptURL = updateTempDir.appendingPathComponent("update.sh")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            let process = Process()
            process.executableURL = scriptURL
            try process.run()
        } catch {
            print("Error installing update: \(error)")
        }
    }
}
