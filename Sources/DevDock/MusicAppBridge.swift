import AppKit

/// Reads and controls Apple's Music app through AppleScript, like SpotifyBridge does for
/// Spotify: what's playing (polled while VYNL follows Apple Music), play/pause/skip/seek, and
/// searching and playing songs in your library. macOS asks once for permission to control Music.
/// Main thread only (NSAppleScript isn't thread-safe).
final class MusicAppBridge: NSObject {
    static let bundleID = "com.apple.Music"

    /// A song in your Music library, from a search.
    struct LibraryTrack: Identifiable, Equatable {
        let id: String // persistent ID
        let title: String
        let artist: String
        let album: String
        let duration: TimeInterval
    }

    var onUpdate: ((NowPlayingInfo?) -> Void)?

    private var timer: Timer?
    private var artworkTrackID: String?
    private var artwork: NSImage?
    private var artworkKey = 0
    private var permissionDenied = false

    private lazy var statusScript: NSAppleScript? = Self.compile("""
    tell application "Music"
        set playerState to player state as string
        if playerState is "stopped" then return {"stopped"}
        set t to current track
        set trackDuration to 0
        try
            set trackDuration to duration of t
        end try
        return {playerState, name of t, artist of t, album of t, trackDuration, player position, persistent ID of t}
    end tell
    """)

    private lazy var artworkScript: NSAppleScript? = Self.compile("""
    tell application "Music" to get raw data of artwork 1 of current track
    """)

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(musicChanged(_:)),
            name: Notification.Name("com.apple.Music.playerInfo"),
            object: nil
        )
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func playPause() { run("playpause") }
    func nextTrack() { run("next track") }
    func previousTrack() { run("previous track") }
    func seek(to seconds: TimeInterval) { run("set player position to \(seconds)") }

    // MARK: - Library

    /// Songs in your library matching `query` (title, artist or album), at most `limit`.
    /// Opens Music if it isn't running: you asked to search it.
    static func searchLibrary(_ query: String, limit: Int = 40) throws -> [LibraryTrack] {
        let text = appleScriptString(query)
        let source = """
        tell application "Music"
            set found to search library playlist 1 for \(text)
            set results to {}
            set total to count of found
            if total > \(limit) then set total to \(limit)
            repeat with i from 1 to total
                set t to item i of found
                set trackDuration to 0
                try
                    set trackDuration to duration of t
                end try
                set end of results to {persistent ID of t, name of t, artist of t, album of t, trackDuration}
            end repeat
            return results
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error), error == nil else {
            throw BridgeError.script(error)
        }
        var tracks: [LibraryTrack] = []
        let count = result.numberOfItems
        guard count > 0 else { return [] }
        for index in 1...count {
            guard let item = result.atIndex(index), item.numberOfItems >= 5 else { continue }
            tracks.append(LibraryTrack(
                id: item.atIndex(1)?.stringValue ?? "",
                title: item.atIndex(2)?.stringValue ?? "",
                artist: item.atIndex(3)?.stringValue ?? "",
                album: item.atIndex(4)?.stringValue ?? "",
                duration: item.atIndex(5)?.doubleValue ?? 0
            ))
        }
        return tracks.filter { !$0.id.isEmpty }
    }

    /// Plays one library song in the Music app.
    static func play(persistentID: String) throws {
        let source = """
        tell application "Music" to play (some track of library playlist 1 whose persistent ID is \(appleScriptString(persistentID)))
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            throw BridgeError.script(error)
        }
    }

    enum BridgeError: LocalizedError {
        case notAllowed
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notAllowed:
                return "VYNL isn't allowed to control Music. Allow it in System Settings > Privacy & Security > Automation."
            case .failed(let message):
                return message
            }
        }

        static func script(_ info: NSDictionary?) -> BridgeError {
            if (info?[NSAppleScript.errorNumber] as? Int) == -1743 {
                return .notAllowed
            }
            return .failed((info?[NSAppleScript.errorMessage] as? String) ?? "Music didn't respond.")
        }
    }

    // MARK: - Private

    @objc private func musicChanged(_ notification: Notification) {
        poll()
    }

    private func poll() {
        // Never use `tell application` when Music is closed: that would launch it.
        guard Self.isRunning, !permissionDenied, let script = statusScript else {
            onUpdate?(nil)
            return
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                permissionDenied = true
                NSLog("VYNL: not allowed to control Music. Enable it in System Settings > Privacy & Security > Automation.")
            }
            onUpdate?(nil)
            return
        }

        // AppleScript lists are 1-based.
        let state = result.atIndex(1)?.stringValue ?? "stopped"
        guard state != "stopped", result.numberOfItems >= 7 else {
            onUpdate?(nil)
            return
        }
        loadArtwork(for: result.atIndex(7)?.stringValue)

        onUpdate?(NowPlayingInfo(
            title: result.atIndex(2)?.stringValue ?? "",
            artist: result.atIndex(3)?.stringValue ?? "",
            album: result.atIndex(4)?.stringValue ?? "",
            duration: result.atIndex(5)?.doubleValue ?? 0,
            elapsed: result.atIndex(6)?.doubleValue ?? 0,
            elapsedAt: Date(),
            playbackRate: 1,
            isPlaying: state == "playing",
            sourceBundleID: Self.bundleID,
            artwork: artwork,
            artworkKey: artworkKey
        ))
    }

    /// Artwork comes as raw image data, fetched once per track.
    private func loadArtwork(for trackID: String?) {
        guard let trackID, trackID != artworkTrackID else { return }
        artworkTrackID = trackID
        var error: NSDictionary?
        let data = artworkScript?.executeAndReturnError(&error).data
        artwork = error == nil ? data.flatMap { NSImage(data: $0) } : nil
        artworkKey += 1
    }

    private func run(_ command: String) {
        guard Self.isRunning, !permissionDenied else { return }
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Music\" to \(command)")?.executeAndReturnError(&error)
        poll()
    }

    private static func compile(_ source: String) -> NSAppleScript? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        script?.compileAndReturnError(&error)
        return script
    }

    /// A quoted AppleScript string literal.
    private static func appleScriptString(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
