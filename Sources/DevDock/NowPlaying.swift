import AppKit
import Combine

/// What's playing right now, from whichever app owns macOS Now Playing.
struct NowPlayingInfo {
    var title: String
    var artist: String
    var album: String
    /// Seconds; 0 when unknown (live streams).
    var duration: TimeInterval
    /// Seconds into the track at `elapsedAt`.
    var elapsed: TimeInterval
    var elapsedAt: Date
    var playbackRate: Double
    var isPlaying: Bool
    /// The app that's playing, e.g. com.spotify.client or com.google.Chrome.
    var sourceBundleID: String
    var artwork: NSImage?
    /// Changes whenever the artwork changes, so views can skip redundant image work.
    var artworkKey: Int

    func currentElapsed(at date: Date = Date()) -> TimeInterval {
        var seconds = elapsed
        if isPlaying {
            seconds += date.timeIntervalSince(elapsedAt) * (playbackRate > 0 ? playbackRate : 1)
        }
        if duration > 0 {
            seconds = min(seconds, duration)
        }
        return max(seconds, 0)
    }
}

/// Commands for playback DevDock runs itself (the SoundCloud player).
enum InternalCommand {
    case togglePlayPause, nextTrack, previousTrack, seek(TimeInterval)
}

enum SourceIDs {
    /// sourceBundleID for tracks DevDock plays itself through SoundCloud's player.
    static let soundCloud = "vynl.soundcloud"
    /// DevDock's own bundle ID. Web audio in DevDock (the SoundCloud tab) reports under it.
    static var devDock: String? { Bundle.main.bundleIdentifier }

    static func isDevDock(_ bundleID: String) -> Bool {
        bundleID == soundCloud || (devDock != nil && bundleID == devDock)
    }
}

/// Names and icons for the source tag.
@MainActor
enum MediaSource {
    private static let knownNames: [String: String] = [
        "com.spotify.client": "Spotify",
        "com.apple.Music": "Apple Music",
        "com.apple.podcasts": "Podcasts",
        "com.apple.TV": "TV",
        "com.apple.Safari": "Safari",
        "com.google.Chrome": "Chrome",
        "company.thebrowser.Browser": "Arc",
        "com.brave.Browser": "Brave",
        "org.mozilla.firefox": "Firefox",
        "com.microsoft.edgemac": "Edge",
        "com.operasoftware.Opera": "Opera",
    ]

    private static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
        "com.brave.Browser", "org.mozilla.firefox", "com.microsoft.edgemac", "com.operasoftware.Opera",
    ]

    static func displayName(for bundleID: String) -> String {
        // Only SoundCloud plays inside DevDock.
        if SourceIDs.isDevDock(bundleID) {
            return "SoundCloud"
        }
        if let name = knownNames[bundleID] {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID.isEmpty ? "Unknown" : bundleID
    }

    static func symbol(for bundleID: String) -> String {
        if SourceIDs.isDevDock(bundleID) { return "cloud.fill" }
        if bundleID == SpotifyBridge.bundleID { return "dot.radiowaves.left.and.right" }
        if browsers.contains(bundleID) { return "globe" }
        return "music.note"
    }
}

/// Merges the ways DevDock learns what's playing:
/// 1. mediaremote-adapter, which sees every player (Spotify, SoundCloud in a browser, Apple
///    Music, YouTube) and can control it.
/// 2. Spotify's AppleScript, used only when the adapter isn't bundled or keeps failing.
/// 3. DevDock's own SoundCloud player ("internal"), which reports exact state itself.
/// Main thread only.
final class NowPlayingService: ObservableObject {
    enum Backend {
        case starting, adapter, spotify
    }

    @Published private(set) var info: NowPlayingInfo?
    @Published private(set) var backend: Backend = .starting

    /// Routes controls to DevDock's SoundCloud player while it's the one showing (set by PlayerStore).
    var onInternalCommand: ((InternalCommand) -> Void)?

    private let adapter = MediaRemoteAdapter()
    private let spotify = SpotifyBridge()
    private var externalInfo: NowPlayingInfo?
    private var internalInfo: NowPlayingInfo?

    func start() {
        spotify.onUpdate = { [weak self] info in
            guard let self, self.backend == .spotify else { return }
            self.externalInfo = info
            self.refresh()
        }
        guard adapter.isInstalled else {
            useSpotifyFallback()
            return
        }
        adapter.onUpdate = { [weak self] info in
            guard let self else { return }
            if self.backend != .adapter {
                self.backend = .adapter
            }
            self.externalInfo = info
            self.refresh()
        }
        adapter.onFailure = { [weak self] in
            self?.useSpotifyFallback()
        }
        adapter.start()
    }

    func stop() {
        adapter.stop()
        spotify.stop()
    }

    /// DevDock's SoundCloud player reports here.
    func setInternal(_ newInfo: NowPlayingInfo?) {
        internalInfo = newInfo
        refresh()
    }

    /// Pauses another app (Spotify, a browser) before DevDock starts a SoundCloud track.
    func pauseExternalPlayback() {
        guard let external = externalInfo, external.isPlaying, !SourceIDs.isDevDock(external.sourceBundleID) else { return }
        if usesAdapter {
            adapter.send(.pause)
        } else {
            spotify.pause()
        }
    }

    // MARK: - Controls

    func togglePlayPause() {
        if showsInternal {
            onInternalCommand?(.togglePlayPause)
            return
        }
        if var current = externalInfo {
            // Flip right away so the record and button respond before the player confirms.
            current.elapsed = current.currentElapsed()
            current.elapsedAt = Date()
            current.isPlaying.toggle()
            externalInfo = current
            refresh()
        }
        if usesAdapter {
            adapter.send(.togglePlayPause)
        } else {
            spotify.playPause()
        }
    }

    func nextTrack() {
        if showsInternal {
            onInternalCommand?(.nextTrack)
        } else if usesAdapter {
            adapter.send(.nextTrack)
        } else {
            spotify.nextTrack()
        }
    }

    func previousTrack() {
        if showsInternal {
            onInternalCommand?(.previousTrack)
        } else if usesAdapter {
            adapter.send(.previousTrack)
        } else {
            spotify.previousTrack()
        }
    }

    func seek(to seconds: TimeInterval) {
        if showsInternal {
            onInternalCommand?(.seek(seconds))
            return
        }
        if var current = externalInfo {
            current.elapsed = seconds
            current.elapsedAt = Date()
            externalInfo = current
            refresh()
        }
        if usesAdapter {
            adapter.seek(to: seconds)
        } else {
            spotify.seek(to: seconds)
        }
    }

    // MARK: - Private

    private var usesAdapter: Bool {
        backend != .spotify && adapter.isInstalled
    }

    /// The SoundCloud player wins while it's playing, when nothing else is, or when the "other"
    /// player is just macOS reporting the same SoundCloud audio coming from DevDock's web view.
    private var showsInternal: Bool {
        guard let internalInfo else { return false }
        guard let external = externalInfo, !SourceIDs.isDevDock(external.sourceBundleID) else { return true }
        return internalInfo.isPlaying || !external.isPlaying
    }

    private func refresh() {
        info = showsInternal ? internalInfo : externalInfo
    }

    private func useSpotifyFallback() {
        guard backend != .spotify else { return }
        NSLog("VYNL: mediaremote-adapter unavailable; showing Spotify only.")
        adapter.stop()
        backend = .spotify
        externalInfo = nil
        refresh()
        spotify.start()
    }
}
