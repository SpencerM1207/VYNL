import AppKit
import SwiftUI
import WebKit

/// Keeps web views alive in a hidden offscreen window while their tab isn't showing, so
/// playback continues when you switch tabs.
@MainActor
final class WebViewParking {
    static let shared = WebViewParking()

    private let window: NSWindow

    private init() {
        window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 640),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.alphaValue = 0
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.orderFrontRegardless()
    }

    func park(_ view: NSView) {
        guard let content = window.contentView else { return }
        view.removeFromSuperview()
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
    }
}

/// Shows a long-lived WKWebView inside SwiftUI and parks it again when the view goes away.
struct HostedWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if webView.superview !== container {
            attach(to: container)
        }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        for case let web as WKWebView in container.subviews {
            WebViewParking.shared.park(web)
        }
    }

    private func attach(to container: NSView) {
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}

/// A music website inside the Music tab: soundcloud.com (when there are no API keys) or
/// Spotify's web player. Signed in with your own account (cookies persist), searched and played
/// on the site itself. The web view is created the first time the tab shows it.
@MainActor
final class MusicWebSession: NSObject, WKUIDelegate {
    /// Buttons on the site's own player bar, for controls when macOS isn't routing them here.
    struct PlayerControls {
        let playPause: String
        let next: String
        let previous: String
    }

    /// Sites serve their full desktop versions to Safari, and Google allows sign-in from it.
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    static func soundCloud() -> MusicWebSession {
        MusicWebSession(
            home: URL(string: "https://soundcloud.com/discover")!,
            popupHosts: ["soundcloud.com", "google.com", "apple.com", "facebook.com"],
            controls: PlayerControls(
                playPause: ".playControls__play",
                next: ".skipControl__next",
                previous: ".skipControl__previous"
            )
        )
    }

    static func spotify() -> MusicWebSession {
        MusicWebSession(
            home: URL(string: "https://open.spotify.com/")!,
            popupHosts: ["spotify.com", "google.com", "apple.com", "facebook.com"],
            controls: PlayerControls(
                playPause: "[data-testid=\"control-button-playpause\"]",
                next: "[data-testid=\"control-button-skip-forward\"]",
                previous: "[data-testid=\"control-button-skip-back\"]"
            )
        )
    }

    let home: URL
    /// Popups from these sites stay in VYNL (sign-in). Other new-window links go to your browser.
    private let popupHosts: [String]
    private let controls: PlayerControls

    /// True while a sign-in popup is open, so the player doesn't collapse behind it (set by PlayerStore).
    var onPopupChange: ((Bool) -> Void)?

    /// False until the tab first shows the site; nothing loads before that.
    private(set) var isLoaded = false
    private(set) lazy var webView: WKWebView = makeWebView()
    private var popups: [WebPopup] = []

    init(home: URL, popupHosts: [String], controls: PlayerControls) {
        self.home = home
        self.popupHosts = popupHosts
        self.controls = controls
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func goHome() { webView.load(URLRequest(url: home)) }

    /// Whether the site is playing something right now (false before it has loaded).
    func isPlaying() async -> Bool {
        guard isLoaded else { return false }
        return await webView.requestMediaPlaybackState() == .playing
    }

    /// Presses the site's own player buttons. Seeking isn't offered by the sites' buttons.
    func perform(_ command: InternalCommand) {
        guard isLoaded else { return }
        let selector: String
        switch command {
        case .togglePlayPause: selector = controls.playPause
        case .nextTrack: selector = controls.next
        case .previousTrack: selector = controls.previous
        case .seek: return
        }
        let quoted = selector
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        webView.evaluateJavaScript("document.querySelector('\(quoted)')?.click();", completionHandler: nil)
    }

    private func makeWebView() -> WKWebView {
        isLoaded = true
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 868, height: 560), configuration: configuration)
        view.customUserAgent = Self.userAgent
        view.pageZoom = 0.8
        view.allowsBackForwardNavigationGestures = true
        view.uiDelegate = self
        view.load(URLRequest(url: home))
        WebViewParking.shared.park(view)
        return view
    }

    // MARK: - WKUIDelegate

    /// "Sign in with Google" (and Apple, Facebook) opens a real popup and reports back to the
    /// page through window.opener. Loading it in place breaks that link and leaves a blank page,
    /// so give it a genuine second web view, built from WebKit's configuration, in its own window.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let url = navigationAction.request.url
        if let url, let host = url.host?.lowercased(),
           !popupHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            NSWorkspace.shared.open(url)
            return nil
        }

        let popupView = WKWebView(frame: .zero, configuration: configuration)
        popupView.customUserAgent = Self.userAgent
        popupView.uiDelegate = self

        let width = windowFeatures.width.map { CGFloat($0.doubleValue) } ?? 500
        let height = windowFeatures.height.map { CGFloat($0.doubleValue) } ?? 640
        let popup = WebPopup(webView: popupView, size: NSSize(width: max(width, 420), height: max(height, 560)))
        popup.onClose = { [weak self, weak popup] in
            guard let self, let popup else { return }
            self.removePopup(popup)
        }
        popups.append(popup)
        onPopupChange?(true)
        popup.show()
        return popupView
    }

    /// The page called window.close(), e.g. after Google finishes signing you in.
    func webViewDidClose(_ webView: WKWebView) {
        popups.first(where: { $0.webView === webView })?.close()
    }

    private func removePopup(_ popup: WebPopup) {
        popups.removeAll { $0 === popup }
        if popups.isEmpty {
            onPopupChange?(false)
        }
    }
}

/// A sign-in popup: a small titled panel above the player that takes typing without
/// activating VYNL (like the player itself).
@MainActor
final class WebPopup: NSObject, NSWindowDelegate {
    let webView: WKWebView
    var onClose: (() -> Void)?

    private let panel: PopupPanel

    init(webView: WKWebView, size: NSSize) {
        self.webView = webView
        panel = PopupPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = "Sign in"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Above the player, which sits at the status bar level.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = webView
        panel.delegate = self
        panel.center()
    }

    func show() {
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func close() {
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        onClose = nil
    }
}

private final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
