import AppKit
import WebKit

/// Plays SoundCloud tracks through SoundCloud's official embeddable player (the Widget API) in a
/// web view, shown as a slim bar in the SoundCloud tab. Web audio runs in WebKit's own process,
/// so it still goes through DevDock's EQ, which only leaves out DevDock's own process.
@MainActor
final class SoundCloudPlayer: NSObject, ObservableObject {
    @Published private(set) var currentTrackID: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?

    /// SoundCloud's mini player. Parked offscreen whenever the SoundCloud tab isn't showing.
    let webView: WKWebView

    /// Pushes what's playing into NowPlayingService (set by PlayerStore).
    var onInfoChange: ((NowPlayingInfo?) -> Void)?
    /// Called just before a track starts, so Spotify or a browser can be paused.
    var willStartPlayback: (() -> Void)?

    private var queue: [SoundCloudTrack] = []
    private var index = 0
    private var info: NowPlayingInfo?
    private var artworkKey = 0
    private var pageReady = false
    private var pageFailed = false
    private var pendingScripts: [String] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 408, height: 20), configuration: configuration)
        super.init()
        webView.configuration.userContentController.add(ScriptMessageProxy(target: self), name: "devdock")
        webView.navigationDelegate = self
        loadPage()
        WebViewParking.shared.park(webView)
    }

    // MARK: - Playback

    /// Plays `track`; the rest of `list` becomes the queue for next and previous.
    func play(_ track: SoundCloudTrack, from list: [SoundCloudTrack]) {
        queue = list.isEmpty ? [track] : list
        index = queue.firstIndex(of: track) ?? 0
        load(queue[index])
    }

    func handle(_ command: InternalCommand) {
        switch command {
        case .togglePlayPause: togglePlayPause()
        case .nextTrack: nextTrack()
        case .previousTrack: previousTrack()
        case .seek(let seconds): seek(to: seconds)
        }
    }

    func togglePlayPause() {
        guard var current = info else { return }
        if !current.isPlaying {
            willStartPlayback?()
        }
        // Flip right away; the widget's play/pause events confirm it.
        current.elapsed = current.currentElapsed()
        current.elapsedAt = Date()
        current.isPlaying.toggle()
        isPlaying = current.isPlaying
        setInfo(current)
        run("devdockToggle()")
    }

    func nextTrack() {
        guard index + 1 < queue.count else { return }
        index += 1
        load(queue[index])
    }

    /// Restarts the track if it's past 3 seconds, otherwise goes to the previous result.
    func previousTrack() {
        if let current = info, current.currentElapsed() > 3 || index == 0 {
            seek(to: 0)
            return
        }
        guard index > 0 else { return }
        index -= 1
        load(queue[index])
    }

    func seek(to seconds: TimeInterval) {
        if var current = info {
            current.elapsed = max(seconds, 0)
            current.elapsedAt = Date()
            setInfo(current)
        }
        run("devdockSeek(\(Int(max(seconds, 0) * 1000)))")
    }

    // MARK: - Private

    private func load(_ track: SoundCloudTrack) {
        guard let url = track.permalinkURL else {
            errorMessage = "That track has no link SoundCloud's player can open."
            return
        }
        willStartPlayback?()
        errorMessage = nil
        currentTrackID = track.id
        isPlaying = true
        artworkKey += 1
        // Show the track right away from the search data; the widget fills in details as it loads.
        setInfo(NowPlayingInfo(
            title: track.title,
            artist: track.artist,
            album: "",
            duration: track.durationSeconds,
            elapsed: 0,
            elapsedAt: Date(),
            playbackRate: 1,
            isPlaying: true,
            sourceBundleID: SourceIDs.soundCloudPlayer,
            artwork: nil,
            artworkKey: artworkKey
        ))
        loadArtwork(track.artworkURL(size: "t500x500"), for: track.id)
        run("devdockLoad(\(Self.javaScriptString(url.absoluteString)))")
    }

    private func setInfo(_ newInfo: NowPlayingInfo?) {
        info = newInfo
        onInfoChange?(newInfo)
    }

    private func loadArtwork(_ url: URL?, for trackID: Int) {
        guard let url else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let image = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let image, self.currentTrackID == trackID, var current = self.info else { return }
                    self.artworkKey += 1
                    current.artwork = image
                    current.artworkKey = self.artworkKey
                    self.setInfo(current)
                }
            }
        }.resume()
    }

    fileprivate func handleMessage(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        let position = (message["position"] as? NSNumber).map { $0.doubleValue / 1000 }
        switch type {
        case "play":
            isPlaying = true
            update(playing: true, position: position)
        case "pause":
            isPlaying = false
            update(playing: false, position: position)
        case "seek", "progress":
            update(playing: nil, position: position)
        case "sound":
            updateMetadata(from: message)
        case "finish":
            if index + 1 < queue.count {
                nextTrack()
            } else {
                isPlaying = false
                update(playing: false, position: nil)
            }
        case "error":
            isPlaying = false
            errorMessage = "SoundCloud's player couldn't play this track. Its uploader may have turned off embedding."
            update(playing: false, position: nil)
        default:
            break
        }
    }

    private func update(playing: Bool?, position: TimeInterval?) {
        guard var current = info else { return }
        if let position {
            current.elapsed = position
            current.elapsedAt = Date()
        } else if let playing, playing != current.isPlaying {
            current.elapsed = current.currentElapsed()
            current.elapsedAt = Date()
        }
        if let playing {
            current.isPlaying = playing
        }
        setInfo(current)
    }

    private func updateMetadata(from message: [String: Any]) {
        guard var current = info else { return }
        if let duration = (message["duration"] as? NSNumber)?.doubleValue, duration > 0 {
            current.duration = duration / 1000
        }
        if current.artist.isEmpty, let artist = message["artist"] as? String {
            current.artist = artist
        }
        setInfo(current)
    }

    private func loadPage() {
        pageReady = false
        pageFailed = false
        webView.loadHTMLString(Self.widgetPage, baseURL: URL(string: "https://devdock.local/"))
    }

    private func run(_ script: String) {
        if pageReady {
            webView.evaluateJavaScript(script, completionHandler: nil)
            return
        }
        pendingScripts.append(script)
        if pageFailed {
            loadPage()
        }
    }

    /// A JSON string literal is a valid JavaScript string literal, with everything escaped.
    private static func javaScriptString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
              let literal = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return literal
    }

    /// SoundCloud's mini player (20 px, dark) plus a small bridge to Swift. Only the newest
    /// progress is sent every 5 s; between updates, NowPlayingInfo extrapolates the position.
    private static let widgetPage = #"""
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <title>DevDock SoundCloud</title>
    <style>
      html, body { margin: 0; padding: 0; background: #0b1214; overflow: hidden; }
      iframe { display: block; border: 0; width: 100%; height: 20px; }
    </style>
    <script src="https://w.soundcloud.com/player/api.js"></script>
    </head>
    <body>
    <iframe id="sc" allow="autoplay" scrolling="no"></iframe>
    <script>
    (function () {
      var post = function (message) { window.webkit.messageHandlers.devdock.postMessage(message); };
      var params = '&auto_play=true&inverse=true&show_user=true&buying=false&sharing=false&download=false&color=%238fdbc9';
      var widget = null;
      var lastProgress = 0;

      function sendSound() {
        widget.getCurrentSound(function (sound) {
          if (!sound) { return; }
          post({
            type: 'sound',
            title: sound.title || '',
            artist: sound.metadata_artist || (sound.user && sound.user.username) || '',
            duration: sound.duration || 0
          });
        });
      }

      function bindAll() {
        var E = SC.Widget.Events;
        widget.bind(E.PLAY, function () {
          widget.getPosition(function (p) { post({ type: 'play', position: p }); });
          sendSound();
        });
        widget.bind(E.PAUSE, function () {
          widget.getPosition(function (p) { post({ type: 'pause', position: p }); });
        });
        widget.bind(E.SEEK, function (e) { post({ type: 'seek', position: e && e.currentPosition }); });
        widget.bind(E.FINISH, function () { post({ type: 'finish' }); });
        widget.bind(E.ERROR, function () { post({ type: 'error' }); });
        widget.bind(E.PLAY_PROGRESS, function (e) {
          var now = Date.now();
          if (now - lastProgress > 5000) {
            lastProgress = now;
            post({ type: 'progress', position: e && e.currentPosition });
          }
        });
      }

      window.devdockLoad = function (url) {
        var iframe = document.getElementById('sc');
        if (!widget) {
          iframe.src = 'https://w.soundcloud.com/player/?url=' + encodeURIComponent(url) + params;
          widget = SC.Widget(iframe);
          bindAll();
        } else {
          widget.load(url, {
            auto_play: true, inverse: true, show_user: true,
            buying: false, sharing: false, download: false, color: '#8fdbc9',
            callback: function () { widget.play(); }
          });
        }
      };
      window.devdockToggle = function () { if (widget) { widget.toggle(); } };
      window.devdockSeek = function (ms) { if (widget) { widget.seekTo(ms); } };
    })();
    </script>
    </body>
    </html>
    """#
}

extension SoundCloudPlayer: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        let scripts = pendingScripts
        pendingScripts = []
        for script in scripts {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageFailed = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageFailed = true
    }
}

/// Forwards widget messages without the user content controller retaining the player.
@MainActor
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: SoundCloudPlayer?

    init(target: SoundCloudPlayer) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.handleMessage(message.body)
    }
}
