import Foundation

// MARK: - Model

/// One timed line of lyrics. Empty text marks an instrumental break, shown as dots.
struct LyricLine: Identifiable, Equatable {
    /// Position in the list, so it doubles as the scroll target.
    let id: Int
    /// Seconds into the track where the line starts.
    let time: TimeInterval
    let text: String

    var isBreak: Bool { text.isEmpty }
}

enum Lyrics: Equatable {
    /// Lines with start times, in order.
    case synced([LyricLine])
    /// Lines without trustworthy timing. Empty strings separate verses. `otherVersion` holds
    /// timed lines from a different version of the song (the original of an extended mix,
    /// say): right words, wrong times, until you tap a line to sync them.
    case plain([String], otherVersion: [LyricLine]?)
    case instrumental
}

/// The song to find lyrics for, built from Now Playing.
struct LyricsQuery: Equatable {
    var title: String
    var artist: String
    var album: String
    /// Seconds; 0 when unknown.
    var duration: TimeInterval

    /// Same song, even when its duration or album arrive a moment after the title.
    var identity: String {
        title.trimmingCharacters(in: .whitespaces).lowercased()
            + "\n" + artist.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

// MARK: - LRC parsing

/// Reads LRC: "[01:02.50]A line", several timestamps per line, [offset:+250], and enhanced
/// word stamps like <01:02.80> (dropped; lines light up whole, like Spotify).
enum LRCParser {
    /// Gaps shorter than this don't get dots.
    static let minimumBreak: TimeInterval = 3

    static func parse(_ text: String) -> [LyricLine] {
        var offset: TimeInterval = 0
        var entries: [(time: TimeInterval, order: Int, text: String)] = []

        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var rest = raw.drop(while: { $0 == " " || $0 == "\t" })
            var times: [TimeInterval] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                guard let time = timestamp(tag) else {
                    // Metadata such as [ar:Artist] or [offset:+250].
                    if times.isEmpty, tag.lowercased().hasPrefix("offset:"),
                       let milliseconds = Double(tag.dropFirst("offset:".count).trimmingCharacters(in: .whitespaces)) {
                        offset = milliseconds / 1000
                    }
                    break
                }
                times.append(time)
                rest = rest[rest.index(after: close)...]
            }
            guard !times.isEmpty else { continue }
            let lyric = cleanLine(String(rest))
            for time in times {
                entries.append((time, entries.count, lyric))
            }
        }

        // The offset covers the whole file wherever the tag sits. Positive shows lines sooner.
        let sorted = entries
            .map { (time: max($0.time - offset, 0), order: $0.order, text: $0.text) }
            .sorted { $0.time != $1.time ? $0.time < $1.time : $0.order < $1.order }

        var merged: [(time: TimeInterval, text: String)] = []
        for entry in sorted {
            if entry.text.isEmpty {
                // Blanks before the first line or right after another blank add nothing.
                guard let last = merged.last, !last.text.isEmpty else { continue }
                merged.append((entry.time, ""))
            } else if let last = merged.last, abs(last.time - entry.time) < 0.01 {
                // Two lines at the same moment (often a translation) show together.
                merged[merged.count - 1].text = last.text.isEmpty ? entry.text : last.text + "\n" + entry.text
            } else {
                merged.append((entry.time, entry.text))
            }
        }

        var kept: [(time: TimeInterval, text: String)] = []
        for (index, entry) in merged.enumerated() {
            if entry.text.isEmpty, index + 1 < merged.count, merged[index + 1].time - entry.time < minimumBreak {
                continue
            }
            kept.append(entry)
        }
        guard kept.contains(where: { !$0.text.isEmpty }) else { return [] }

        // Dots through the intro when the singing starts late.
        if let first = kept.first, first.time >= minimumBreak {
            kept.insert((0, ""), at: 0)
        }
        return kept.enumerated().map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
    }

    /// "mm:ss.xx", "mm:ss.xxx", "mm:ss" or "mm:ss:xx" in seconds; nil for anything else.
    static func timestamp<S: StringProtocol>(_ tag: S) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, isDigits(parts[0]), let minutes = Int(parts[0]) else { return nil }
        var secondsText = String(parts[1])
        if parts.count == 3 {
            guard isDigits(parts[2]) else { return nil }
            secondsText += "." + String(parts[2])
        }
        guard let first = secondsText.first, first.isASCII, first.isNumber,
              secondsText.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." }),
              let seconds = Double(secondsText)
        else { return nil }
        return Double(minutes) * 60 + seconds
    }

    /// Lines without timing, with runs of blank lines kept as one verse break.
    static func plainLines(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty {
                lines.append(line)
            } else if let last = lines.last, !last.isEmpty {
                lines.append("")
            }
        }
        while lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    /// The line being sung at `time`: the last one that has started. nil before the first.
    static func index(at time: TimeInterval, in lines: [LyricLine]) -> Int? {
        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].time <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low == 0 ? nil : low - 1
    }

    private static func cleanLine(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\d+:\\d+(?:[.:]\\d+)?>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isDigits<S: StringProtocol>(_ text: S) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

// MARK: - Matching

/// Tidies the names players report so they match LRCLIB's, and scores candidates.
enum LyricsMatcher {
    /// Letters and digits only, lowercased, accents removed: "Señorita (Remix)" → "senoritaremix".
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var scalars = String.UnicodeScalarView()
        for scalar in folded.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// "Song (feat. X)", "Song [Official Video]", "Song - 2011 Remaster", "Song ft. X" → "Song".
    static func cleanTitle(_ title: String) -> String {
        var text = title
        text = text.replacingOccurrences(
            of: "\\s*[(\\[][^)\\]]*\\b(feat|ft|featuring|with|prod|official|lyrics?|audio|video|visuali[sz]er|remaster(ed)?|explicit|clean|hd|hq|4k|mv)\\b[^)\\]]*[)\\]]",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "\\s+[-–—]\\s+[^-–—]*\\b(remaster(ed)?|version|edit|live|mono|stereo|bonus|demo|from|acoustic|session)\\b.*$",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "\\s+(feat\\.?|ft\\.?|featuring)\\s+.*$",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? title.trimmingCharacters(in: .whitespaces) : text
    }

    /// For searching: `cleanTitle` without any bracketed part or mix suffix, since LRCLIB usually
    /// files the original. "Comes and Goes (Extended Mix)" → "Comes and Goes".
    static func searchTitle(_ title: String) -> String {
        var text = cleanTitle(title)
        text = text.replacingOccurrences(of: "\\s*[(\\[][^)\\]]*[)\\]]", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "\\s+[-–—]\\s+[^-–—]*\\b(mix|remix|edit|vip|dub|bootleg|flip|extended|instrumental|rework)\\b.*$",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? cleanTitle(title) : text
    }

    /// LRCLIB's search fails with a server error on brackets and similar symbols, so searches
    /// keep only letters, digits and apostrophes: "KETTAMA (G-TOWN)" → "KETTAMA G TOWN".
    static func searchText(_ text: String) -> String {
        var result = ""
        for character in text {
            result.append(character.isLetter || character.isNumber || character == "'" || character == "’" ? character : " ")
        }
        return result.split(separator: " ").joined(separator: " ")
    }

    /// "A, B", "A & B", "A x B", "A feat. B", "A (Label)" → "A". YouTube's "A - Topic" and "AVEVO" → "A".
    static func primaryArtist(_ artist: String) -> String {
        var text = artist
        text = text.replacingOccurrences(of: "\\s*[(\\[][^)\\]]*[)\\]]", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+-\\s+topic$", with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "VEVO$", with: "", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "\\s*(,|;|\\s/\\s|\\s&\\s|\\sx\\s|\\s(feat\\.?|ft\\.?|featuring|with)\\s).*$",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? artist.trimmingCharacters(in: .whitespaces) : text
    }

    /// Words that mark a version with its own timing: "Comes and Goes (Extended Mix)" →
    /// ["extended", "mix"]. A lookup can't trust another version's timing without the track length.
    static func versionMarkers(in title: String) -> Set<String> {
        let markers = [
            "extended", "mix", "remix", "edit", "vip", "live", "sped up", "slowed", "nightcore",
            "acoustic", "bootleg", "flip", "rework", "dub", "instrumental", "mashup", "cover",
        ]
        let lowered = title.lowercased()
        return Set(markers.filter { lowered.range(of: "\\b\($0)\\b", options: .regularExpression) != nil })
    }

    /// SoundCloud and YouTube uploads are often titled "Artist - Song".
    static func splitArtistTitle(_ title: String) -> (artist: String, title: String)? {
        for separator in [" - ", " – ", " — "] {
            guard let range = title.range(of: separator) else { continue }
            let artist = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let song = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty, !song.isEmpty {
                return (artist, song)
            }
        }
        return nil
    }
}

// MARK: - LRCLIB

/// Lyrics from LRCLIB (lrclib.net), a free, open database of synced lyrics. No account or key.
/// Asks for the exact song and searches with tidied names at the same time, then tries an
/// "Artist - Title" split and free text, and keeps the best match: the title has to match;
/// synced beats plain; a close track length and the right artist add confidence.
/// Results are cached per song.
actor LyricsClient {
    enum Lookup: Equatable {
        case found(Lyrics)
        case notFound
    }

    enum LyricsError: LocalizedError {
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .http(let status): return "LRCLIB had a problem (HTTP \(status))."
            }
        }
    }

    static let shared = LyricsClient()

    /// Candidates below this score are probably a different song.
    private static let minimumScore = 60
    /// Synced and this sure: stop asking.
    private static let greatScore = 130
    private static let cacheLimit = 80
    private static let userAgent = "VYNL/1.0 (macOS music widget)"

    private let session: URLSession
    private var cache: [String: Lookup] = [:]
    private var cacheOrder: [String] = []

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 12
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        session = URLSession(configuration: configuration)
    }

    func lyrics(for query: LyricsQuery) async throws -> Lookup {
        // Without the track length a match can't be checked as well, so the answer may change
        // once the length is known: cache the two separately.
        let key = query.identity + (query.duration > 0 ? "" : "\n(no length)")
        if let cached = cache[key] {
            return cached
        }
        let result = try await lookUp(query)
        cache[key] = result
        cacheOrder.append(key)
        if cacheOrder.count > Self.cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
        return result
    }

    // MARK: - Private

    private struct Track: Decodable {
        let id: Int
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private struct Candidate {
        let lyrics: Lyrics
        let score: Int

        var isGreat: Bool {
            guard case .synced = lyrics else { return false }
            return score >= LyricsClient.greatScore
        }
    }

    /// Everything the scoring needs to recognize the song under its different spellings.
    private struct Names {
        let titles: Set<String>
        let artists: Set<String>
        let duration: TimeInterval
        /// "extended", "remix" and the like in the playing title.
        let markers: Set<String>
    }

    private func lookUp(_ query: LyricsQuery) async throws -> Lookup {
        let title = query.title.trimmingCharacters(in: .whitespaces)
        let artist = query.artist.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return .notFound }

        let searchTitle = LyricsMatcher.searchTitle(title)
        let mainArtist = artist.isEmpty ? "" : LyricsMatcher.primaryArtist(artist)
        let split = LyricsMatcher.splitArtistTitle(title)
        let splitTitle = split.map { LyricsMatcher.searchTitle($0.title) }
        let splitArtist = split.map { LyricsMatcher.primaryArtist($0.artist) }

        let titleVariants = [title, LyricsMatcher.cleanTitle(title), searchTitle, splitTitle ?? ""]
        let artistVariants = [artist, mainArtist, splitArtist ?? ""]
        let names = Names(
            titles: Set(titleVariants.map(LyricsMatcher.normalized)).subtracting([""]),
            artists: Set(artistVariants.map(LyricsMatcher.normalized)).subtracting([""]),
            duration: query.duration,
            markers: LyricsMatcher.versionMarkers(in: title)
        )

        var best: Candidate?
        var anyAnswered = false
        var lastError: Error?
        func consider(_ result: Result<[Track], Error>) {
            switch result {
            case .success(let tracks):
                anyAnswered = true
                for track in tracks {
                    guard let candidate = evaluate(track, names),
                          candidate.score >= Self.minimumScore,
                          candidate.score > (best?.score ?? Int.min)
                    else { continue }
                    best = candidate
                }
            case .failure(let error):
                lastError = error
            }
        }

        // 1. The exact song as the player reports it, and a search with tidied names, together.
        var exactItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if !query.album.isEmpty {
            exactItems.append(URLQueryItem(name: "album_name", value: query.album))
        }
        if (1...3600).contains(query.duration) {
            exactItems.append(URLQueryItem(name: "duration", value: String(Int(query.duration.rounded()))))
        }
        // A constant copy: async let mustn't capture a var.
        let exactRequest = artist.isEmpty ? nil : exactItems
        async let exact = tracks("/api/get", exactRequest, single: true)
        async let searched = tracks("/api/search", searchQuery(title: searchTitle, artist: mainArtist), single: false)
        consider(await searched)
        if best?.isGreat != true {
            consider(await exact)
        }

        // 2. SoundCloud and YouTube uploads titled "Artist - Song".
        if best?.isGreat != true, let splitTitle, let splitArtist,
           let items = searchQuery(title: splitTitle, artist: splitArtist) {
            consider(await tracks("/api/search", items, single: false))
        }

        // 3. Free text, for players with odd tags.
        if best == nil {
            let text = LyricsMatcher.searchText([mainArtist, searchTitle].joined(separator: " "))
            if !text.isEmpty {
                consider(await tracks("/api/search", [URLQueryItem(name: "q", value: text)], single: false))
            }
        }

        if let best {
            return .found(best.lyrics)
        }
        // A fallback search failing doesn't make the whole lookup a failure.
        if !anyAnswered, let lastError {
            throw lastError
        }
        return .notFound
    }

    private func searchQuery(title: String, artist: String) -> [URLQueryItem]? {
        let cleanTitle = LyricsMatcher.searchText(title)
        guard !cleanTitle.isEmpty else { return nil }
        var items = [URLQueryItem(name: "track_name", value: cleanTitle)]
        let cleanArtist = LyricsMatcher.searchText(artist)
        if !cleanArtist.isEmpty {
            items.append(URLQueryItem(name: "artist_name", value: cleanArtist))
        }
        return items
    }

    /// One request, decoded; no items means nothing to ask. `single` for /api/get, which
    /// answers with one track instead of a list.
    private func tracks(_ path: String, _ items: [URLQueryItem]?, single: Bool) async -> Result<[Track], Error> {
        guard let items else { return .success([]) }
        do {
            try Task.checkCancellation()
            guard let data = try await request(path, items) else { return .success([]) }
            let decoder = JSONDecoder()
            if single {
                return .success([try decoder.decode(Track.self, from: data)])
            }
            return .success(try decoder.decode([Track].self, from: data))
        } catch {
            return .failure(error)
        }
    }

    /// nil when it's another song. The title has to match; without the artist, only a track of
    /// the same length counts. Timing is trusted only when the lengths agree within 8 s; with no
    /// length to compare, only when the candidate is the same version ("Extended Mix" playing
    /// and plain "Comes and Goes" found means the timing is for the original). Untrusted timing
    /// is kept as `otherVersion`, so a tap on the right line can still sync it.
    private func evaluate(_ track: Track, _ names: Names) -> Candidate? {
        let name = LyricsMatcher.normalized(track.trackName ?? "")
        var score: Int
        if names.titles.contains(name) {
            score = 40
        } else if name.count >= 4, names.titles.contains(where: { $0.count >= 4 && (name.contains($0) || $0.contains(name)) }) {
            score = 15
        } else {
            return nil
        }

        let difference: TimeInterval? = {
            guard names.duration > 0, let trackDuration = track.duration, trackDuration > 0 else { return nil }
            return abs(trackDuration - names.duration)
        }()

        let artistName = LyricsMatcher.normalized(track.artistName ?? "")
        let artistMatches = !artistName.isEmpty
            && names.artists.contains(where: { $0.count >= 2 && (artistName.contains($0) || $0.contains(artistName)) })
        if artistMatches {
            score += 30
        } else if (difference ?? .infinity) > 3 {
            return nil
        }

        let synced = track.syncedLyrics.map(LRCParser.parse) ?? []
        let plain = track.plainLyrics.map(LRCParser.plainLines) ?? []
        let timingFits: Bool
        if let difference {
            timingFits = difference <= 8
        } else {
            timingFits = names.markers.isSubset(of: LyricsMatcher.versionMarkers(in: track.trackName ?? ""))
        }
        let lyrics: Lyrics
        if !synced.isEmpty && timingFits {
            lyrics = .synced(synced)
            score += 60
        } else if !synced.isEmpty {
            lyrics = .plain(plain.isEmpty ? synced.filter { !$0.isBreak }.map(\.text) : plain, otherVersion: synced)
            score += 30
        } else if !plain.isEmpty {
            lyrics = .plain(plain, otherVersion: nil)
            score += 30
        } else if track.instrumental == true {
            lyrics = .instrumental
            score += 20
        } else {
            return nil
        }

        if let difference {
            score += difference <= 2 ? 30 : difference <= 5 ? 15 : difference <= 10 ? 0 : -15
        }
        return Candidate(lyrics: lyrics, score: score)
    }

    /// The body for 200, nil for "no such song" (404) or a rejected query (400).
    private func request(_ path: String, _ items: [URLQueryItem]) async throws -> Data? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = path
        components.queryItems = items
        // URLComponents leaves "+" alone, which servers read as a space ("Love + Fear").
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { return nil }
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            return data
        case 400, 404:
            return nil
        default:
            NSLog("VYNL: LRCLIB %@ returned HTTP %ld", path, status)
            throw LyricsError.http(status)
        }
    }
}
