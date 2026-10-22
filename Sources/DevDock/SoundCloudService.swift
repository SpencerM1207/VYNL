import AppKit
import Combine

/// A track from the SoundCloud API (GET /tracks). Field names follow the API's snake_case
/// through JSONDecoder's convertFromSnakeCase.
struct SoundCloudTrack: Identifiable, Hashable, Decodable {
    struct User: Hashable, Decodable {
        let username: String?
        let avatarUrl: String?
    }

    let id: Int
    let title: String
    let duration: Int?          // milliseconds
    let permalinkUrl: String?
    let artworkUrl: String?
    let access: String?         // "playable", "preview" (Go+ snippet) or "blocked"
    let metadataArtist: String?
    let user: User?

    var artist: String {
        if let name = metadataArtist, !name.isEmpty { return name }
        return user?.username ?? ""
    }

    var durationSeconds: TimeInterval { Double(duration ?? 0) / 1000 }
    var isPreview: Bool { access == "preview" }
    var permalinkURL: URL? { permalinkUrl.flatMap { URL(string: $0) } }

    /// Artwork URLs end in "-large.jpg" (100 px). Swap the size token, e.g. "t67x67" or "t500x500".
    /// Falls back to the uploader's avatar, as SoundCloud's own apps do.
    func artworkURL(size: String) -> URL? {
        guard let base = artworkUrl ?? user?.avatarUrl, !base.isEmpty else { return nil }
        return URL(string: base.replacingOccurrences(of: "-large.", with: "-\(size)."))
    }
}

struct SoundCloudTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double?
}

/// API keys plus the cached access token, in ~/Library/Application Support/VYNL/soundcloud.json,
/// readable only by this user. A file rather than the Keychain because an ad hoc signed app would
/// trigger a Keychain password prompt after every rebuild. The secret only reads public content.
struct SoundCloudSecrets: Codable {
    var clientID: String
    var clientSecret: String
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Date?

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VYNL", isDirectory: true).appendingPathComponent("soundcloud.json")
    }

    static func load() -> SoundCloudSecrets? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SoundCloudSecrets.self, from: data)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func save() throws {
        let url = Self.fileURL
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(self)
        // Created with owner-only permissions from the start.
        guard fileManager.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    mutating func apply(_ token: SoundCloudTokenResponse) {
        accessToken = token.accessToken
        refreshToken = token.refreshToken ?? refreshToken
        expiresAt = Date().addingTimeInterval(token.expiresIn ?? 3600)
    }
}

enum SoundCloudError: LocalizedError {
    case noCredentials
    case rejectedKeys
    case rateLimited
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "Add your SoundCloud API keys first."
        case .rejectedKeys: return "SoundCloud didn't accept those keys. Check the Client ID and Secret."
        case .rateLimited: return "SoundCloud is rate-limiting requests right now. Try again in a little while."
        case .http(let status): return "SoundCloud returned an error (HTTP \(status))."
        case .badResponse: return "SoundCloud sent a response VYNL couldn't read."
        }
    }
}

/// SoundCloud search through the official API (client credentials flow).
/// Token rules from the docs: tokens last about an hour, refresh tokens are single-use, and
/// new tokens are limited to 50 per 12 hours, so the token is cached on disk and refreshed.
@MainActor
final class SoundCloudService: ObservableObject {
    enum SearchState: Equatable {
        case idle, searching, done, failed(String)
    }

    @Published var query = ""
    @Published private(set) var results: [SoundCloudTrack] = []
    @Published private(set) var state: SearchState = .idle
    @Published private(set) var hasCredentials: Bool

    private var secrets: SoundCloudSecrets?
    private var searchTask: Task<Void, Never>?
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private static let tokenURL = URL(string: "https://secure.soundcloud.com/oauth/token")!
    private static let tracksURL = URL(string: "https://api.soundcloud.com/tracks")!

    init() {
        let loaded = SoundCloudSecrets.load()
        secrets = loaded
        hasCredentials = loaded != nil
    }

    func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        guard !text.isEmpty else {
            clearResults()
            return
        }
        state = .searching
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let tracks = try await self.fetchTracks(matching: text)
                guard !Task.isCancelled else { return }
                self.results = tracks
                self.state = .done
            } catch is CancellationError {
                // A newer search replaced this one.
            } catch let error as URLError where error.code == .cancelled {
                // Same, from URLSession.
            } catch {
                guard !Task.isCancelled else { return }
                self.state = .failed(Self.describe(error))
            }
        }
    }

    func clearResults() {
        searchTask?.cancel()
        results = []
        state = .idle
    }

    /// Checks the keys by requesting a token, then saves them. Returns an error message, or nil.
    func saveCredentials(clientID: String, clientSecret: String) async -> String? {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else {
            return "Paste both the Client ID and the Client Secret."
        }
        var candidate = SoundCloudSecrets(clientID: id, clientSecret: secret)
        do {
            let token = try await requestToken(grant: ["grant_type": "client_credentials"], secrets: candidate)
            candidate.apply(token)
            try candidate.save()
            secrets = candidate
            hasCredentials = true
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    func removeCredentials() {
        SoundCloudSecrets.delete()
        secrets = nil
        hasCredentials = false
        query = ""
        clearResults()
    }

    // MARK: - Private

    private struct SearchPage: Decodable {
        let collection: [SoundCloudTrack]
        let nextHref: String?
    }

    private func fetchTracks(matching text: String) async throws -> [SoundCloudTrack] {
        var components = URLComponents(url: Self.tracksURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "access", value: "playable,preview"),
            URLQueryItem(name: "limit", value: "40"),
            URLQueryItem(name: "linked_partitioning", value: "true"),
        ]
        guard let url = components.url else { throw SoundCloudError.badResponse }
        let data = try await authorizedData(from: url)
        do {
            return try decoder.decode(SearchPage.self, from: data).collection.filter { $0.access != "blocked" }
        } catch {
            throw SoundCloudError.badResponse
        }
    }

    private func authorizedData(from url: URL) async throws -> Data {
        var token = try await validAccessToken()
        for attempt in 0..<2 {
            var request = URLRequest(url: url)
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Accept")
            request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 {
                token = try await validAccessToken(forceNew: true)
                continue
            }
            if status == 429 { throw SoundCloudError.rateLimited }
            guard (200..<300).contains(status) else { throw SoundCloudError.http(status) }
            return data
        }
        throw SoundCloudError.rejectedKeys
    }

    private func validAccessToken(forceNew: Bool = false) async throws -> String {
        guard var current = secrets else { throw SoundCloudError.noCredentials }
        if !forceNew,
           let token = current.accessToken,
           let expiry = current.expiresAt,
           expiry > Date().addingTimeInterval(60) {
            return token
        }
        var fresh: SoundCloudTokenResponse?
        if let refresh = current.refreshToken {
            fresh = try? await requestToken(
                grant: ["grant_type": "refresh_token", "refresh_token": refresh],
                secrets: current
            )
        }
        if fresh == nil {
            fresh = try await requestToken(grant: ["grant_type": "client_credentials"], secrets: current)
        }
        guard let fresh else { throw SoundCloudError.badResponse }
        current.apply(fresh)
        try? current.save()
        secrets = current
        return fresh.accessToken
    }

    private func requestToken(grant: [String: String], secrets: SoundCloudSecrets) async throws -> SoundCloudTokenResponse {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let basic = Data("\(secrets.clientID):\(secrets.clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.httpBody = Self.formBody(grant)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            do {
                return try decoder.decode(SoundCloudTokenResponse.self, from: data)
            } catch {
                throw SoundCloudError.badResponse
            }
        case 400, 401, 403:
            throw SoundCloudError.rejectedKeys
        case 429:
            throw SoundCloudError.rateLimited
        default:
            throw SoundCloudError.http(status)
        }
    }

    private static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "Couldn't reach SoundCloud (\(urlError.localizedDescription))."
        }
        return error.localizedDescription
    }
}
