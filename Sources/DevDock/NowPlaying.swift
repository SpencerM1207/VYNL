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
    /// The app that's playing, e.g. com.spotify.client or com.google.Chrome, or one of
    /// VYNL's own players (`SourceIDs`).
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

/// Commands for playback VYNL runs itself (the SoundCloud player and its web players).
enum InternalCommand {
    case togglePlayPause, nextTrack, previousTrack, seek(TimeInterval)
}

/// Which app Now Playing follows. Auto shows whatever macOS says is playing; the others stick
/// to one app's song and controls even when something else is also playing.
enum PlayerSource: String, CaseIterable, Identifiable {
    case auto, spotify, soundCloud, appleMusic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .spotify: return "Spotify"
        case .soundCloud: return "SoundCloud"
        case .appleMusic: return "Apple Music"
        }
    }

    /// The desktop app to open when it isn't running.
    var appBundleID: String? {
        switch self {
        case .spotify: return SpotifyBridge.bundleID
        case .appleMusic: return MusicAppBridge.bundleID
        case .auto, .soundCloud: return nil
        }
    }
}

enum SourceIDs {
    /// VYNL's own SoundCloud player (native search with API keys).
    static let soundCloudPlayer = "vynl.soundcloud"
    /// soundcloud.com in VYNL's Music tab.
    static let soundCloudWeb = "vynl.soundcloud.web"
    /// Spotify's web player in VYNL's Music tab.
    static let spotifyWeb = "vynl.spotify.web"
    /// VYNL's own bundle ID. Its web players report to Now Playing under it.
    static var devDock: String? { Bundle.main.bundleIdentifier }

    /// Audio VYNL plays itself.
    static func isDevDock(_ bundleID: String) -> Bool {
        bundleID == soundCloudPlayer || bundleID == soundCloudWeb || bundleID == spotifyWeb
            || (devDock != nil && bundleID == devDock)
    }

    /// The service behind a source, for following and labeling.
    static func service(of bundleID: String) -> PlayerSource? {
        switch bundleID {
        case SpotifyBridge.bundleID, spotifyWeb: return .spotify
        case MusicAppBridge.bundleID: return .appleMusic
        case soundCloudPlayer, soundCloudWeb: return .soundCloud
        default: return devDock == bundleID ? .soundCloud : nil
        }
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
        if SourceIDs.isDevDock(bundleID) {
            return SourceIDs.service(of: bundleID) == .spotify ? "Spotify" : "SoundCloud"
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
        switch SourceIDs.service(of: bundleID) {
        case .spotify: return "dot.radiowaves.left.and.right"
        case .soundCloud: return "cloud.fill"
        case .appleMusic: return "music.note"
        case .auto, nil: return browsers.contains(bundleID) ? "globe" : "music.note"
        }
    }
}

/// Merges the ways VYNL learns what's playing:
/// 1. mediaremote-adapter, which sees whichever player macOS considers current (Spotify,
///    SoundCloud in a browser, Apple Music, YouTube) and can control it.
/// 2. Spotify's and Music's AppleScript, polled while VYNL follows that app (and Spotify's when
///    the adapter isn't bundled).
/// 3. VYNL's own SoundCloud player ("internal"), which reports exact state itself.
/// `followed` picks which of these the player shows; controls go to whichever app that is.
/// Main thread only.
final class NowPlayingService: ObservableObject {
    enum Backend {
        case starting, adapter, spotify
    }

    @Published private(set) var info: NowPlayingInfo?
    @Published private(set) var backend: Backend = .starting
    /// Which app to follow (Settings, or the source tag's menu). Saved.
    @Published var followed: PlayerSource {
        didSet {
            UserDefaults.standard.set(followed.rawValue, forKey: Self.followedKey)
            updateBridges()
            refresh()
        }
    }

    /// Routes controls to VYNL's SoundCloud player while it's the one showing (set by PlayerStore).
    var onInternalCommand: ((InternalCommand) -> Void)?
    /// Controls for VYNL's own web players when macOS isn't routing commands to them (set by PlayerStore).
    var onWebCommand: ((PlayerSource, InternalCommand) -> Void)?
    /// Called when macOS reports audio from VYNL itself, so PlayerStore can work out which of its
    /// web players it is and set `ownWebSource`.
    var onOwnWebAudio: (() -> Void)?
    /// Which of VYNL's web players is making the sound VYNL reports: Spotify or SoundCloud.
    var ownWebSource: PlayerSource = .soundCloud {
        didSet {
            if ownWebSource != oldValue {
                refresh()
            }
        }
    }

    private static let followedKey = "followedSource"

    private let adapter = MediaRemoteAdapter()
    private let spotify = SpotifyBridge()
    private let music = MusicAppBridge()
    /// The adapter's report as it came (or Spotify's, in fallback mode).
    private var externalRaw: NowPlayingInfo?
    private var internalInfo: NowPlayingInfo?
    /// From the bridges, while following those apps.
    private var spotifyInfo: NowPlayingInfo?
    private var musicInfo: NowPlayingInfo?
    /// The last SoundCloud song seen, for following SoundCloud while something else plays.
    private var lastSoundCloudInfo: NowPlayingInfo?

    init() {
        followed = UserDefaults.standard.string(forKey: Self.followedKey).flatMap(PlayerSource.init(rawValue:)) ?? .auto
    }

    func start() {
        spotify.onUpdate = { [weak self] info in
            guard let self else { return }
            self.spotifyInfo = info
            if self.backend == .spotify {
                self.externalRaw = info
            }
            self.refresh()
        }
        music.onUpdate = { [weak self] info in
            self?.musicInfo = info
            self?.refresh()
        }
        updateBridges()
        guard adapter.isInstalled else {
            useSpotifyFallback()
            return
        }
        adapter.onUpdate = { [weak self] info in
            guard let self else { return }
            if self.backend != .adapter {
                self.backend = .adapter
            }
            let changedTrack = info?.title != self.externalRaw?.title || info?.isPlaying != self.externalRaw?.isPlaying
            self.externalRaw = info
            if let info, info.sourceBundleID == SourceIDs.devDock, changedTrack {
                self.onOwnWebAudio?()
            }
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
        music.stop()
    }

    /// VYNL's SoundCloud player reports here.
    func setInternal(_ newInfo: NowPlayingInfo?) {
        internalInfo = newInfo
        refresh()
    }

    /// Pauses another app (Spotify, a browser) before VYNL starts a SoundCloud track.
    func pauseExternalPlayback() {
        guard let external = externalRaw, external.isPlaying, !SourceIDs.isDevDock(external.sourceBundleID) else { return }
        if usesAdapter {
            adapter.send(.pause)
        } else {
            spotify.pause()
        }
    }

    /// Opens the followed app when nothing is playing in it.
    func openFollowedApp() {
        guard let bundleID = followed.appBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Controls

    func togglePlayPause() {
        switch target {
        case .internalPlayer:
            onInternalCommand?(.togglePlayPause)
        case .adapter:
            if var current = externalRaw {
                // Flip right away so the record and button respond before the player confirms.
                current.elapsed = current.currentElapsed()
                current.elapsedAt = Date()
                current.isPlaying.toggle()
                externalRaw = current
                refresh()
            }
            adapter.send(.togglePlayPause)
        case .spotifyApp:
            spotify.playPause()
        case .musicApp:
            music.playPause()
        case .web(let service):
            onWebCommand?(service, .togglePlayPause)
        case .none:
            // Following an app with nothing loaded: ask it to play.
            switch followed {
            case .spotify: spotify.playPause()
            case .appleMusic: music.playPause()
            case .auto, .soundCloud: break
            }
        }
    }

    func nextTrack() {
        switch target {
        case .internalPlayer: onInternalCommand?(.nextTrack)
        case .adapter: adapter.send(.nextTrack)
        case .spotifyApp: spotify.nextTrack()
        case .musicApp: music.nextTrack()
        case .web(let service): onWebCommand?(service, .nextTrack)
        case .none: break
        }
    }

    func previousTrack() {
        switch target {
        case .internalPlayer: onInternalCommand?(.previousTrack)
        case .adapter: adapter.send(.previousTrack)
        case .spotifyApp: spotify.previousTrack()
        case .musicApp: music.previousTrack()
        case .web(let service): onWebCommand?(service, .previousTrack)
        case .none: break
        }
    }

    func seek(to seconds: TimeInterval) {
        switch target {
        case .internalPlayer:
            onInternalCommand?(.seek(seconds))
        case .adapter:
            if var current = externalRaw {
                current.elapsed = seconds
                current.elapsedAt = Date()
                externalRaw = current
                refresh()
            }
            adapter.seek(to: seconds)
        case .spotifyApp:
            spotify.seek(to: seconds)
        case .musicApp:
            music.seek(to: seconds)
        case .web(let service):
            onWebCommand?(service, .seek(seconds))
        case .none:
            break
        }
    }

    // MARK: - Private

    /// Where commands for the song on show go.
    private enum Target {
        case internalPlayer, adapter, spotifyApp, musicApp, web(PlayerSource), none
    }

    private var target: Target {
        guard let info else { return .none }
        if info.sourceBundleID == SourceIDs.soundCloudPlayer {
            return .internalPlayer
        }
        // macOS sends commands to its current player, which is the adapter's report.
        if usesAdapter, let external, external.sourceBundleID == info.sourceBundleID {
            return .adapter
        }
        switch info.sourceBundleID {
        case SpotifyBridge.bundleID: return .spotifyApp
        case MusicAppBridge.bundleID: return .musicApp
        case SourceIDs.spotifyWeb: return .web(.spotify)
        case SourceIDs.soundCloudWeb: return .web(.soundCloud)
        default: return usesAdapter ? .adapter : .spotifyApp
        }
    }

    private var usesAdapter: Bool {
        backend != .spotify && adapter.isInstalled
    }

    /// The adapter's report, with VYNL's own web audio labeled as Spotify or SoundCloud.
    private var external: NowPlayingInfo? {
        guard var info = externalRaw else { return nil }
        if info.sourceBundleID == SourceIDs.devDock {
            info.sourceBundleID = ownWebSource == .spotify ? SourceIDs.spotifyWeb : SourceIDs.soundCloudWeb
        }
        return info
    }

    /// In Auto, the SoundCloud player wins while it's playing, when nothing else is, or when the
    /// "other" player is just macOS reporting VYNL's own web audio.
    private var showsInternal: Bool {
        guard let internalInfo else { return false }
        guard let external = externalRaw, !SourceIDs.isDevDock(external.sourceBundleID) else { return true }
        return internalInfo.isPlaying || !external.isPlaying
    }

    private func refresh() {
        let external = self.external
        if let external, SourceIDs.service(of: external.sourceBundleID) == .soundCloud {
            lastSoundCloudInfo = external
        }
        switch followed {
        case .auto:
            info = showsInternal ? internalInfo : external
        case .spotify:
            info = Self.matching(external, .spotify) ?? spotifyInfo
        case .appleMusic:
            info = Self.matching(external, .appleMusic) ?? musicInfo
        case .soundCloud:
            if let internalInfo, internalInfo.isPlaying {
                info = internalInfo
            } else if let current = Self.matching(external, .soundCloud) {
                info = current
            } else if let internalInfo {
                info = internalInfo
            } else if var last = lastSoundCloudInfo {
                // Something else took over macOS Now Playing: show the SoundCloud song, paused.
                last.elapsed = last.currentElapsed()
                last.elapsedAt = Date()
                last.isPlaying = false
                info = last
            } else {
                info = nil
            }
        }
    }

    private static func matching(_ info: NowPlayingInfo?, _ service: PlayerSource) -> NowPlayingInfo? {
        guard let info, SourceIDs.service(of: info.sourceBundleID) == service else { return nil }
        return info
    }

    /// Polls Spotify while following it (or as the fallback) and Music while following it.
    private func updateBridges() {
        if backend == .spotify || followed == .spotify {
            spotify.start()
        } else {
            spotify.stop()
            spotifyInfo = nil
        }
        if followed == .appleMusic {
            music.start()
        } else {
            music.stop()
            musicInfo = nil
        }
    }

    private func useSpotifyFallback() {
        guard backend != .spotify else { return }
        NSLog("VYNL: mediaremote-adapter unavailable; showing Spotify only.")
        adapter.stop()
        backend = .spotify
        externalRaw = nil
        updateBridges()
        refresh()
    }
}
