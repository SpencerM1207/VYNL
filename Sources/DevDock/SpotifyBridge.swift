import AppKit

/// Fallback when mediaremote-adapter isn't bundled: reads and controls the Spotify desktop app
/// through AppleScript. macOS asks once for permission to control Spotify.
/// Main thread only (NSAppleScript isn't thread-safe).
final class SpotifyBridge: NSObject {
    static let bundleID = "com.spotify.client"

    var onUpdate: ((NowPlayingInfo?) -> Void)?

    private var timer: Timer?
    private var artworkURL: String?
    private var artwork: NSImage?
    private var artworkKey = 0
    private var permissionDenied = false

    private lazy var statusScript: NSAppleScript? = {
        let script = NSAppleScript(source: """
        tell application "Spotify"
            set trackState to player state as string
            if trackState is "stopped" then return {"stopped"}
            set t to current track
            return {trackState, name of t, artist of t, album of t, duration of t, player position, artwork url of t}
        end tell
        """)
        var error: NSDictionary?
        script?.compileAndReturnError(&error)
        return script
    }()

    private var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
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
            selector: #selector(spotifyChanged(_:)),
            name: Notification.Name("com.spotify.client.PlaybackStateChanged"),
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
    func pause() { run("pause") }
    func nextTrack() { run("next track") }
    func previousTrack() { run("previous track") }
    func seek(to seconds: TimeInterval) { run("set player position to \(seconds)") }

    // MARK: - Private

    @objc private func spotifyChanged(_ notification: Notification) {
        poll()
    }

    private func poll() {
        // Never use `tell application` when Spotify is closed: that would launch it.
        guard isRunning, !permissionDenied, let script = statusScript else {
            onUpdate?(nil)
            return
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            // -1743: the user said no to "VYNL wants to control Spotify".
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                permissionDenied = true
                NSLog("VYNL: not allowed to control Spotify. Enable it in System Settings > Privacy & Security > Automation.")
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
        let durationMilliseconds = result.atIndex(5)?.doubleValue ?? 0
        let position = result.atIndex(6)?.doubleValue ?? 0
        loadArtwork(from: result.atIndex(7)?.stringValue)

        onUpdate?(NowPlayingInfo(
            title: result.atIndex(2)?.stringValue ?? "",
            artist: result.atIndex(3)?.stringValue ?? "",
            album: result.atIndex(4)?.stringValue ?? "",
            duration: durationMilliseconds / 1000,
            elapsed: position,
            elapsedAt: Date(),
            playbackRate: 1,
            isPlaying: state == "playing",
            sourceBundleID: Self.bundleID,
            artwork: artwork,
            artworkKey: artworkKey
        ))
    }

    private func loadArtwork(from urlString: String?) {
        guard let urlString, urlString != artworkURL, let url = URL(string: urlString) else { return }
        artworkURL = urlString
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let image = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async {
                guard let self, self.artworkURL == urlString else { return }
                self.artwork = image
                self.artworkKey += 1
                self.poll()
            }
        }.resume()
    }

    private func run(_ command: String) {
        guard isRunning, !permissionDenied else { return }
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Spotify\" to \(command)")?.executeAndReturnError(&error)
        poll()
    }
}
