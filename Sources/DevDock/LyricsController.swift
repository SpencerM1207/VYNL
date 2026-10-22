import Combine
import Foundation

/// Finds lyrics for whatever's playing and follows along: `currentIndex` is the line being sung.
/// Lyrics load only while the lyrics column is turned on, and the line timer runs only while the
/// column is on screen and music is playing.
///
/// Timing: each song can carry its own offset (tap the line you hear, or nudge), saved by
/// title and artist. Lyrics timed for another version (an extended mix found only as the
/// original) start unsynced and become synced with one tap.
/// Songs LRCLIB doesn't have get a live transcription instead, when that's turned on.
@MainActor
final class LyricsController: ObservableObject {
    enum Status: Equatable {
        case idle, loading, loaded(Lyrics), notFound
        /// With a short reason to show.
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    /// The followed line being sung; nil before the first line or with nothing to follow.
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    /// Seconds added to every line's time for this song; positive shows lyrics later.
    @Published private(set) var offset: TimeInterval = 0
    /// This song has a saved timing of its own.
    @Published private(set) var hasCustomTiming = false
    /// Timing controls are open: tapping a line syncs it to now instead of seeking.
    @Published var isAdjusting = false

    let transcriber = LyricsTranscriber()

    /// Changes with each song's lyrics, so views can start fresh (scrolled to the top, following).
    private(set) var contentID = ""
    /// Live transcription for songs LRCLIB doesn't have (Settings).
    private(set) var transcribesMissingLyrics = true

    /// Lines light up this much early, so the highlight lands with the voice instead of after it.
    static let lead: TimeInterval = 0.2
    /// Lets rapid skipping settle before asking for lyrics.
    private static let fetchDelay: TimeInterval = 0.35
    /// Web players report the track length a moment after the title. Without the length a
    /// match for another version can't be spotted, so wait this long for it.
    private static let lengthWait: TimeInterval = 3
    /// People tap a moment after a line starts.
    private static let tapReaction: TimeInterval = 0.35
    private static let offsetsKey = "lyricsOffsets"

    private let nowPlaying: NowPlayingService
    private var info: NowPlayingInfo?
    private var query: LyricsQuery?
    private var loadedIdentity: String?
    private var loadedWithLength = false
    private var loadTask: Task<Void, Never>?
    private var timer: Timer?
    private var wantsLyrics = false
    private var isVisible = false
    private var offsets: [String: Double]
    private var cancellables = Set<AnyCancellable>()

    init(nowPlaying: NowPlayingService) {
        self.nowPlaying = nowPlaying
        offsets = UserDefaults.standard.dictionary(forKey: Self.offsetsKey) as? [String: Double] ?? [:]
    }

    func start(dock: DockModel) {
        nowPlaying.$info
            .sink { [weak self] info in self?.infoChanged(info) }
            .store(in: &cancellables)
        // @Published sends new values before the properties change, so use the values passed in.
        dock.$isExpanded
            .combineLatest(dock.$mode, dock.$showsLyrics, dock.$transcribesLyrics)
            .sink { [weak self] expanded, mode, shows, transcribes in
                self?.settingsChanged(
                    wanted: shows,
                    visible: expanded && mode == .player && shows,
                    transcribes: transcribes
                )
            }
            .store(in: &cancellables)
    }

    /// The timed lines being followed: synced lyrics, or another version's once you've synced it.
    var followedLines: [LyricLine] {
        switch status {
        case .loaded(.synced(let lines)):
            return lines
        case .loaded(.plain(_, otherVersion: let lines?)) where hasCustomTiming:
            return lines
        default:
            return []
        }
    }

    /// Track length in seconds; 0 when unknown.
    var duration: TimeInterval { info?.duration ?? 0 }

    /// Where the song is in lyric time (lead and offset applied), for the dots that fill during
    /// instrumental breaks.
    func position(at date: Date) -> TimeInterval {
        (info?.currentElapsed(at: date) ?? 0) + Self.lead - offset
    }

    /// Clicking a line jumps the song there.
    func seek(to line: LyricLine) {
        nowPlaying.seek(to: max(line.time + offset, 0))
    }

    /// "This is the line I'm hearing": shifts every line so this one starts about now.
    func sync(to line: LyricLine) {
        guard let info, let identity = loadedIdentity else { return }
        setOffset(info.currentElapsed() - Self.tapReaction - line.time, for: identity)
    }

    /// Positive shows lyrics later.
    func nudge(by seconds: TimeInterval) {
        guard let identity = loadedIdentity else { return }
        setOffset(offset + seconds, for: identity)
    }

    func resetTiming() {
        guard let identity = loadedIdentity else { return }
        offsets[identity] = nil
        UserDefaults.standard.set(offsets, forKey: Self.offsetsKey)
        offset = 0
        hasCustomTiming = false
        isAdjusting = false
        updateIndex()
        updateTimer()
    }

    func retry() {
        loadTask?.cancel()
        loadTask = nil
        loadedIdentity = nil
        if query != nil {
            status = .loading
        }
        load(after: 0)
    }

    // MARK: - Private

    private func infoChanged(_ newInfo: NowPlayingInfo?) {
        info = newInfo
        let newQuery = newInfo.map {
            LyricsQuery(title: $0.title, artist: $0.artist, album: $0.album, duration: $0.duration)
        }
        let isNewSong = newQuery?.identity != query?.identity
        query = newQuery
        if isNewSong {
            songChanged()
        } else if let newQuery, newQuery.duration > 0, !loadedWithLength, loadedIdentity == newQuery.identity {
            // Looked up before the length was known: check the match again now that it is.
            loadedIdentity = nil
            load(after: 0)
        }
        let playing = newInfo?.isPlaying ?? false
        if playing != isPlaying {
            isPlaying = playing
        }
        updateIndex()
        updateTimer()
    }

    private func songChanged() {
        loadTask?.cancel()
        loadTask = nil
        loadedIdentity = nil
        loadedWithLength = false
        currentIndex = nil
        offset = 0
        hasCustomTiming = false
        isAdjusting = false
        transcriber.stop()
        guard let query, !query.title.trimmingCharacters(in: .whitespaces).isEmpty else {
            status = .idle
            return
        }
        status = .loading
        load(after: Self.fetchDelay)
    }

    private func settingsChanged(wanted: Bool, visible: Bool, transcribes: Bool) {
        wantsLyrics = wanted
        isVisible = visible
        transcribesMissingLyrics = transcribes
        load(after: 0)
        updateIndex()
        updateTimer()
        updateTranscription()
    }

    private func load(after delay: TimeInterval) {
        guard wantsLyrics, loadTask == nil, let query, query.identity != loadedIdentity,
              !query.title.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }
        let identity = query.identity
        loadTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            var waited: TimeInterval = 0
            while !Task.isCancelled, waited < Self.lengthWait,
                  let current = self?.query, current.identity == identity, current.duration <= 0 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                waited += 0.25
            }
            // Use the latest details: the length and album often arrive just after the title.
            guard !Task.isCancelled, let latest = self?.query, latest.identity == identity else { return }
            let outcome: Status
            do {
                switch try await LyricsClient.shared.lyrics(for: latest) {
                case .found(let lyrics):
                    outcome = .loaded(lyrics)
                case .notFound:
                    outcome = .notFound
                }
            } catch {
                outcome = .failed(Self.describe(error))
                if !Task.isCancelled {
                    // Messages go in as arguments: a URL's "%20" would be read as a format code.
                    NSLog("VYNL: lyrics lookup failed for %@: %@", identity.debugDescription, String(describing: error))
                }
            }
            guard !Task.isCancelled, let self, self.query?.identity == identity else { return }
            self.loadTask = nil
            self.loadedIdentity = identity
            self.loadedWithLength = latest.duration > 0
            self.contentID = identity
            self.offset = self.offsets[identity] ?? 0
            self.hasCustomTiming = self.offsets[identity] != nil
            self.status = outcome
            self.updateIndex()
            self.updateTimer()
            self.updateTranscription()
        }
    }

    private func setOffset(_ seconds: TimeInterval, for identity: String) {
        let rounded = (seconds * 100).rounded() / 100
        offsets[identity] = rounded
        UserDefaults.standard.set(offsets, forKey: Self.offsetsKey)
        offset = rounded
        hasCustomTiming = true
        updateIndex()
        updateTimer()
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "You're offline."
            case .timedOut:
                return "LRCLIB took too long to answer."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Couldn't reach lrclib.net. A network filter may be blocking it."
            default:
                return urlError.localizedDescription
            }
        }
        if error is DecodingError {
            return "LRCLIB sent something VYNL couldn't read."
        }
        return error.localizedDescription
    }

    private func updateIndex() {
        var newIndex: Int?
        let lines = followedLines
        if let info, !lines.isEmpty {
            newIndex = LRCParser.index(at: info.currentElapsed() + Self.lead - offset, in: lines)
        }
        if newIndex != currentIndex {
            currentIndex = newIndex
        }
    }

    /// Ten checks a second while the lyrics are on screen and playing; none otherwise.
    private func updateTimer() {
        let needed = isVisible && isPlaying && !followedLines.isEmpty
        if needed, timer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateIndex()
                }
            }
            timer.tolerance = 0.02
            // .common keeps it ticking while you scroll the lyrics.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !needed, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    /// Listens only while the column shows a song LRCLIB doesn't have.
    private func updateTranscription() {
        if transcribesMissingLyrics, isVisible, status == .notFound, let identity = loadedIdentity {
            transcriber.start(songID: identity)
        } else {
            transcriber.stop()
        }
    }
}
