import AppKit
import Foundation
import Observation

// MARK: - Playback State

/// Represents the current playback state.
nonisolated enum PlaybackState: String, Sendable {
    case playing, paused, stopped
}

// MARK: - Now Playing Song Model

/// A model representing the currently playing song.
nonisolated struct NowPlayingSong: Equatable, Identifiable, Sendable {
    var id: String { title + artist }
    let appName: String
    let state: PlaybackState
    let title: String
    let artist: String
    let albumArtURL: URL?
    let position: Double?
    let duration: Double?  // Duration in seconds

    /// Initializes a song model from a given output string.
    /// - Parameters:
    ///   - application: The name of the music application.
    ///   - output: The output string returned by AppleScript.
    init?(application: String, from output: String) {
        let components = output.components(separatedBy: "|")
        guard components.count == 6,
            let state = PlaybackState(rawValue: components[0])
        else {
            return nil
        }
        // Replace commas with dots for correct decimal conversion.
        let positionString = components[4].replacingOccurrences(
            of: ",", with: ".")
        let durationString = components[5].replacingOccurrences(
            of: ",", with: ".")
        guard let position = Double(positionString),
            let duration = Double(durationString)
        else {
            return nil
        }

        self.appName = application
        self.state = state
        self.title = components[1]
        self.artist = components[2]
        self.albumArtURL = URL(string: components[3])
        self.position = position
        if application == MusicApp.spotify.rawValue {
            self.duration = duration / 1000
        } else {
            self.duration = duration
        }
    }
}

// MARK: - Supported Music Applications

/// Supported music applications with corresponding AppleScript commands.
nonisolated enum MusicApp: String, CaseIterable, Sendable {
    case spotify = "Spotify"
    case music = "Music"

    /// AppleScript to fetch the now playing song.
    var nowPlayingScript: String {
        if self == .music {
            return """
                if application "Music" is running then
                    tell application "Music"
                        if player state is playing or player state is paused then
                            set currentTrack to current track
                            try
                                set artworkURL to (get URL of artwork 1 of currentTrack) as text
                            on error
                                set artworkURL to ""
                            end try
                            set stateText to ""
                            if player state is playing then
                                set stateText to "playing"
                            else if player state is paused then
                                set stateText to "paused"
                            end if
                            return stateText & "|" & (name of currentTrack) & "|" & (artist of currentTrack) & "|" & artworkURL & "|" & (player position as text) & "|" & ((duration of currentTrack) as text)
                        else
                            return "stopped"
                        end if
                    end tell
                else
                    return "stopped"
                end if
                """
        } else {
            return """
                if application "\(rawValue)" is running then
                    tell application "\(rawValue)"
                        if player state is playing then
                            set currentTrack to current track
                            return "playing|" & (name of currentTrack) & "|" & (artist of currentTrack) & "|" & (artwork url of currentTrack) & "|" & player position & "|" & (duration of currentTrack)
                        else if player state is paused then
                            set currentTrack to current track
                            return "paused|" & (name of currentTrack) & "|" & (artist of currentTrack) & "|" & (artwork url of currentTrack) & "|" & player position & "|" & (duration of currentTrack)
                        else
                            return "stopped"
                        end if
                    end tell
                else
                    return "stopped"
                end if
                """
        }
    }

    var previousTrackCommand: String {
        "tell application \"\(rawValue)\" to previous track"
    }

    var togglePlayPauseCommand: String {
        "tell application \"\(rawValue)\" to playpause"
    }

    var nextTrackCommand: String {
        "tell application \"\(rawValue)\" to next track"
    }

    /// Distributed notification name posted by this app when playback state changes.
    var playbackStateNotification: Notification.Name {
        switch self {
        case .spotify: return Notification.Name("com.spotify.client.PlaybackStateChanged")
        case .music: return Notification.Name("com.apple.Music.playerInfo")
        }
    }
}

// MARK: - Now Playing Provider

/// Provides functionality to fetch the now playing song and execute playback commands.
nonisolated enum NowPlayingProvider {

    private static let scriptTimeout: TimeInterval = 2.0

    /// Returns the current playing song from any of the given running apps.
    @concurrent
    static func fetchNowPlaying(from runningApps: [MusicApp]) async
        -> NowPlayingSong?
    {
        for app in runningApps {
            if let output = await runAppleScript(app.nowPlayingScript),
                output != "stopped",
                let song = NowPlayingSong(application: app.rawValue, from: output)
            {
                return song
            }
        }
        return nil
    }

    /// Supported music apps that are currently running. Checked up front so no
    /// AppleScript subprocess is spawned for apps that aren't open.
    @MainActor
    static func runningMusicApps() -> [MusicApp] {
        let names = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.localizedName))
        return MusicApp.allCases.filter { names.contains($0.rawValue) }
    }

    /// Executes the provided AppleScript via the centralized SubprocessRunner.
    /// Bounded by a 2s timeout to prevent hangs when the music app is unresponsive.
    @discardableResult
    static func runAppleScript(_ script: String) async -> String? {
        guard let scriptData = script.data(using: .utf8) else { return nil }
        guard
            let result = await SubprocessRunner.run(
                executable: "/usr/bin/osascript",
                arguments: [],
                stdin: scriptData,
                timeout: scriptTimeout)
        else {
            return nil
        }
        if result.timedOut { return nil }
        let output = String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Executes a playback command for the active music application.
    @MainActor
    static func executeCommand(
        _ command: @escaping @Sendable (MusicApp) -> String
    ) async {
        guard let activeApp = runningMusicApps().first else { return }
        await runAppleScript(command(activeApp))
    }
}

// MARK: - Now Playing Manager

/// An observable manager that keeps the now playing song up to date.
///
/// Primary update path is event-driven via `DistributedNotificationCenter` — both
/// Music.app and Spotify post notifications on play/pause/track change. While
/// something is playing, a 1-second tick keeps the playback position fresh;
/// otherwise the tick slows to 10 seconds, avoiding an `osascript` fork every
/// second while music is paused or no player is running.
@MainActor
@Observable
final class NowPlayingManager {
    static let shared = NowPlayingManager()

    private(set) var nowPlaying: NowPlayingSong?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isUpdating = false

    private init() {
        // Event-driven refresh.
        let center = DistributedNotificationCenter.default()
        for app in MusicApp.allCases {
            center.addObserver(
                forName: app.playbackStateNotification, object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateNowPlaying() }
            }
        }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateNowPlaying()
                let isPlaying = self?.nowPlaying?.state == .playing
                try? await Task.sleep(for: .seconds(isPlaying ? 1 : 10))
            }
        }
    }

    /// Updates the now playing song asynchronously.
    /// Skips the tick if a previous fetch is still in flight.
    private func updateNowPlaying() {
        guard !isUpdating else { return }
        let apps = NowPlayingProvider.runningMusicApps()
        guard !apps.isEmpty else {
            if nowPlaying != nil { nowPlaying = nil }
            return
        }
        isUpdating = true
        Task {
            let song = await NowPlayingProvider.fetchNowPlaying(from: apps)
            if song != nowPlaying { nowPlaying = song }
            isUpdating = false
        }
    }

    private func perform(_ command: @escaping @Sendable (MusicApp) -> String) {
        Task {
            await NowPlayingProvider.executeCommand(command)
            updateNowPlaying()
        }
    }

    /// Skips to the previous track.
    func previousTrack() {
        perform { $0.previousTrackCommand }
    }

    /// Toggles between play and pause.
    func togglePlayPause() {
        perform { $0.togglePlayPauseCommand }
    }

    /// Skips to the next track.
    func nextTrack() {
        perform { $0.nextTrackCommand }
    }
}
