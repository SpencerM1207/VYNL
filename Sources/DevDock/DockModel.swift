import Combine
import Foundation

/// Which tab the full player shows.
enum PanelMode: String {
    case player, music, settings
}

/// Which service the Music tab shows.
enum MusicService: String, CaseIterable, Identifiable {
    case spotify, soundCloud, appleMusic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spotify: return "Spotify"
        case .soundCloud: return "SoundCloud"
        case .appleMusic: return "Apple Music"
        }
    }
}

/// Which side of the Now Playing tab the lyrics column sits on.
enum LyricsSide: String, CaseIterable {
    case left, right
}

/// Window state shared by both panels and the menu bar item. Main thread only.
/// Deliberately not @MainActor so SwiftUI helpers outside `body` can read it on any SDK.
final class DockModel: ObservableObject {
    /// True while the full player is showing. Also gates the spectrum analyzer.
    @Published var isExpanded = false

    /// Now Playing, Music or Settings. Kept between openings.
    @Published var mode: PanelMode = .player

    /// The service the Music tab shows. Saved.
    @Published var musicService: MusicService {
        didSet { UserDefaults.standard.set(musicService.rawValue, forKey: Keys.musicService) }
    }

    /// Keeps the player open while something VYNL owns is in front of it (a sign-in popup).
    @Published var holdOpen = false

    /// Pinned: the player stays open when you click another app.
    @Published var isPinned: Bool {
        didSet { UserDefaults.standard.set(isPinned, forKey: Keys.isPinned) }
    }

    /// The lyrics column beside the Now Playing tab. On by default.
    @Published var showsLyrics: Bool {
        didSet { UserDefaults.standard.set(showsLyrics, forKey: Keys.showsLyrics) }
    }

    /// Right by default.
    @Published var lyricsSide: LyricsSide {
        didSet { UserDefaults.standard.set(lyricsSide.rawValue, forKey: Keys.lyricsSide) }
    }

    /// For songs LRCLIB doesn't have, write down what VYNL hears. On by default.
    @Published var transcribesLyrics: Bool {
        didSet { UserDefaults.standard.set(transcribesLyrics, forKey: Keys.transcribesLyrics) }
    }

    init() {
        let defaults = UserDefaults.standard
        isPinned = defaults.bool(forKey: Keys.isPinned)
        showsLyrics = defaults.object(forKey: Keys.showsLyrics) as? Bool ?? true
        lyricsSide = defaults.string(forKey: Keys.lyricsSide).flatMap(LyricsSide.init(rawValue:)) ?? .right
        transcribesLyrics = defaults.object(forKey: Keys.transcribesLyrics) as? Bool ?? true
        musicService = defaults.string(forKey: Keys.musicService).flatMap(MusicService.init(rawValue:)) ?? .soundCloud
    }

    private enum Keys {
        static let isPinned = "isPinned"
        static let showsLyrics = "showsLyrics"
        static let lyricsSide = "lyricsSide"
        static let transcribesLyrics = "transcribesLyrics"
        static let musicService = "musicService"
    }
}
