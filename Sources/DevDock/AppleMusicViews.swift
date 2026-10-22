import AppKit
import SwiftUI

/// Apple Music in the Music tab. Apple's web player won't play inside other apps, so this
/// searches two places and leaves playback to the Music app: songs in your library play right
/// away; songs from the Apple Music catalog (Apple's public iTunes Search API, no account
/// needed) open in Music, where you press play.
@MainActor
final class AppleMusicSearch: ObservableObject {
    enum SearchState: Equatable {
        case idle, searching, done
        case failed(String)
    }

    struct CatalogSong: Identifiable, Equatable {
        let id: Int
        let title: String
        let artist: String
        let album: String
        let duration: TimeInterval
        let artworkURL: URL?
        /// music://… so it opens in the Music app rather than a browser.
        let musicURL: URL?
    }

    @Published var query = ""
    @Published private(set) var library: [MusicAppBridge.LibraryTrack] = []
    @Published private(set) var catalog: [CatalogSong] = []
    @Published private(set) var state: SearchState = .idle
    @Published private(set) var libraryMessage: String?
    @Published private(set) var playingID: String?

    private var searchTask: Task<Void, Never>?

    func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        guard !text.isEmpty else {
            clear()
            return
        }
        state = .searching
        // Your library, through the Music app.
        do {
            library = try MusicAppBridge.searchLibrary(text)
            libraryMessage = nil
        } catch {
            library = []
            libraryMessage = error.localizedDescription
        }
        // The catalog, over the network.
        searchTask = Task { [weak self] in
            do {
                let songs = try await Self.searchCatalog(text)
                guard !Task.isCancelled else { return }
                self?.catalog = songs
                self?.state = .done
            } catch {
                guard !Task.isCancelled else { return }
                self?.catalog = []
                let hasLibraryResults = !(self?.library.isEmpty ?? true)
                self?.state = hasLibraryResults ? .done : .failed("Couldn't search Apple Music: \(error.localizedDescription)")
            }
        }
    }

    func clear() {
        searchTask?.cancel()
        library = []
        catalog = []
        libraryMessage = nil
        state = .idle
    }

    func play(_ track: MusicAppBridge.LibraryTrack) {
        do {
            try MusicAppBridge.play(persistentID: track.id)
            playingID = track.id
            libraryMessage = nil
        } catch {
            libraryMessage = error.localizedDescription
        }
    }

    func open(_ song: CatalogSong) {
        guard let url = song.musicURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Private

    private struct CatalogResponse: Decodable {
        let results: [Result]

        struct Result: Decodable {
            let trackId: Int?
            let trackName: String?
            let artistName: String?
            let collectionName: String?
            let trackTimeMillis: Double?
            let artworkUrl100: String?
            let trackViewUrl: String?
        }
    }

    private static func searchCatalog(_ text: String) async throws -> [CatalogSong] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: text),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US"),
        ]
        guard let url = components.url else { return [] }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(CatalogResponse.self, from: data)
        return decoded.results.compactMap { result in
            guard let id = result.trackId, let title = result.trackName else { return nil }
            return CatalogSong(
                id: id,
                title: title,
                artist: result.artistName ?? "",
                album: result.collectionName ?? "",
                duration: (result.trackTimeMillis ?? 0) / 1000,
                // 100x100 is small for a retina row; the same URL serves other sizes.
                artworkURL: result.artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100", with: "120x120")) },
                musicURL: result.trackViewUrl.flatMap(musicAppURL(from:))
            )
        }
    }

    /// https://music.apple.com/us/album/x/123?i=456 → music://music.apple.com/us/album/x/123?i=456
    private static func musicAppURL(from webURL: String) -> URL? {
        guard var components = URLComponents(string: webURL) else { return nil }
        components.scheme = "music"
        components.queryItems = components.queryItems?.filter { $0.name != "uo" }
        return components.url
    }
}

/// The Apple Music pane: one search, library songs first, then the Apple Music catalog.
struct AppleMusicPane: View {
    @Environment(\.theme) private var theme
    @ObservedObject var search: AppleMusicSearch

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            HStack {
                Text("Plays in the Music app. Catalog songs open in Music.")
                Spacer()
                Button("Open Music") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MusicAppBridge.bundleID) {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
            }
            .font(theme.font(9, .medium))
            .foregroundStyle(theme.textSecondary)
        }
        .onAppear { searchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(theme.font(11, .semibold))
                .foregroundStyle(theme.textSecondary)
            TextField("Search your library and Apple Music", text: $search.query)
                .textFieldStyle(.plain)
                .font(theme.font(12))
                .foregroundStyle(theme.textPrimary)
                .focused($searchFocused)
                .onSubmit { search.search() }
            if search.state == .searching {
                ProgressView()
                    .controlSize(.small)
            } else if !search.query.isEmpty {
                Button {
                    search.query = ""
                    search.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(searchFocused ? theme.accent.opacity(0.5) : Color.white.opacity(0.08))
        )
    }

    @ViewBuilder
    private var content: some View {
        switch search.state {
        case .idle:
            hint("Search for a song or artist, then press Return.")
        case .failed(let message):
            Text(message)
                .font(theme.font(11))
                .foregroundStyle(Color.orange.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        case .searching where search.library.isEmpty && search.catalog.isEmpty:
            hint("Searching…")
        default:
            if search.library.isEmpty && search.catalog.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    hint("No results.")
                    libraryNote
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if !search.library.isEmpty {
                            sectionHeader("In your library")
                            ForEach(search.library) { track in
                                AppleMusicRow(
                                    title: track.title,
                                    artist: track.artist,
                                    duration: track.duration,
                                    artworkURL: nil,
                                    badge: nil,
                                    isCurrent: search.playingID == track.id
                                ) {
                                    search.play(track)
                                }
                            }
                        }
                        libraryNote
                        if !search.catalog.isEmpty {
                            sectionHeader("Apple Music")
                            ForEach(search.catalog) { song in
                                AppleMusicRow(
                                    title: song.title,
                                    artist: song.artist,
                                    duration: song.duration,
                                    artworkURL: song.artworkURL,
                                    badge: "OPEN",
                                    isCurrent: false
                                ) {
                                    search.open(song)
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }

    @ViewBuilder
    private var libraryNote: some View {
        if let message = search.libraryMessage {
            Text(message)
                .font(theme.font(10))
                .foregroundStyle(Color.orange.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(theme.font(9, .semibold))
            .tracking(1.1)
            .foregroundStyle(theme.textSecondary)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .padding(.horizontal, 8)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(theme.font(11))
            .foregroundStyle(theme.textSecondary)
            .padding(.top, 6)
    }
}

/// One result row: artwork (or a note icon), title, artist, a badge and the length.
private struct AppleMusicRow: View {
    @Environment(\.theme) private var theme
    let title: String
    let artist: String
    let duration: TimeInterval
    let artworkURL: URL?
    let badge: String?
    let isCurrent: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AsyncImage(url: artworkURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(theme.font(11))
                                    .foregroundStyle(theme.textSecondary)
                            )
                    }
                }
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(theme.font(12, .semibold))
                        .foregroundStyle(isCurrent ? theme.accent : theme.textPrimary)
                        .lineLimit(1)
                    Text(artist)
                        .font(theme.font(10))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if let badge {
                    Text(badge)
                        .font(theme.font(8, .bold))
                        .tracking(0.6)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15)))
                        .help("Opens in the Music app")
                }
                if duration > 0 {
                    Text(formatTime(duration))
                        .font(theme.mono(10, .medium))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isCurrent ? theme.accent.opacity(0.12) : Color.white.opacity(hovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
