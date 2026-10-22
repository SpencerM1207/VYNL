import AppKit
import SwiftUI

/// The Music tab: pick Spotify, SoundCloud or Apple Music, then browse and play it here.
/// Spotify: its web player, signed in with your account. SoundCloud: VYNL's own search with API
/// keys, soundcloud.com otherwise. Apple Music: your library and the catalog, played in Music.
struct MusicPane: View {
    @Environment(\.theme) private var theme
    @ObservedObject var dock: DockModel
    let soundCloud: SoundCloudService
    let soundCloudPlayer: SoundCloudPlayer
    let soundCloudWeb: MusicWebSession
    let spotifyWeb: MusicWebSession
    let appleMusic: AppleMusicSearch

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            servicePicker
            switch dock.musicService {
            case .spotify:
                WebMusicPane(session: spotifyWeb, siteName: "open.spotify.com", homeHelp: "Spotify home") {
                    if Self.isInstalled(SpotifyBridge.bundleID) {
                        Button {
                            Self.open(SpotifyBridge.bundleID)
                        } label: {
                            Label("Open the Spotify app", systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(.plain)
                        .font(theme.font(10, .semibold))
                        .foregroundStyle(theme.accent)
                    }
                }
            case .soundCloud:
                SoundCloudPane(service: soundCloud, player: soundCloudPlayer, webSession: soundCloudWeb)
            case .appleMusic:
                AppleMusicPane(search: appleMusic)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Three capsules, like the tabs above.
    private var servicePicker: some View {
        HStack(spacing: 2) {
            ForEach(MusicService.allCases) { service in
                let selected = dock.musicService == service
                Button {
                    dock.musicService = service
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: service.symbol)
                            .font(theme.font(9, .semibold))
                        Text(service.title)
                            .font(theme.font(10, .semibold))
                    }
                    .foregroundStyle(selected ? theme.accent : theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(selected ? theme.accent.opacity(0.14) : Color.clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
    }

    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static func open(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

extension MusicService {
    var symbol: String {
        switch self {
        case .spotify: return "dot.radiowaves.left.and.right"
        case .soundCloud: return "cloud.fill"
        case .appleMusic: return "music.note"
        }
    }
}

extension PlayerSource {
    var symbol: String {
        switch self {
        case .auto: return "waveform"
        case .spotify: return MusicService.spotify.symbol
        case .soundCloud: return MusicService.soundCloud.symbol
        case .appleMusic: return MusicService.appleMusic.symbol
        }
    }

    /// The Music tab page for this service.
    var musicService: MusicService? {
        switch self {
        case .auto: return nil
        case .spotify: return .spotify
        case .soundCloud: return .soundCloud
        case .appleMusic: return .appleMusic
        }
    }

    /// What the desktop app is called (Apple Music's app is just "Music").
    var appName: String {
        self == .appleMusic ? "Music" : title
    }
}
