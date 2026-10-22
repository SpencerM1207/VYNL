import AppKit
import Combine

/// The menu bar icon (the VYNL logo): a second way to open the player, plus playback, the EQ switch, pin and
/// Quit. The same menu shows when you right-click the record.
@MainActor
final class StatusItemController: NSObject {
    let menu: NSMenu

    private let statusItem: NSStatusItem
    private let dock: DockController
    private let store: PlayerStore
    private let playItem = NSMenuItem()
    private let eqItem = NSMenuItem()
    private let pinItem = NSMenuItem()
    private let lyricsItem = NSMenuItem()
    private var cancellables = Set<AnyCancellable>()

    init(dock: DockController, store: PlayerStore) {
        self.dock = dock
        self.store = store
        menu = NSMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = VynlLogo.menuBarImage()
            button.setAccessibilityLabel("VYNL")
            button.toolTip = "VYNL"
        }

        let toggleItem = NSMenuItem(title: "Show Player", action: #selector(togglePlayer), keyEquivalent: "m")
        toggleItem.keyEquivalentModifierMask = [.control, .option]
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        playItem.title = "Play"
        playItem.action = #selector(playPause)
        playItem.target = self
        menu.addItem(playItem)

        let nextItem = NSMenuItem(title: "Next Track", action: #selector(nextTrack), keyEquivalent: "")
        nextItem.target = self
        menu.addItem(nextItem)

        let previousItem = NSMenuItem(title: "Previous Track", action: #selector(previousTrack), keyEquivalent: "")
        previousItem.target = self
        menu.addItem(previousItem)

        menu.addItem(.separator())

        eqItem.title = "Equalizer"
        eqItem.action = #selector(toggleEQ)
        eqItem.target = self
        menu.addItem(eqItem)

        lyricsItem.title = "Lyrics"
        lyricsItem.action = #selector(toggleLyrics)
        lyricsItem.target = self
        menu.addItem(lyricsItem)

        pinItem.title = "Keep Open When Unfocused"
        pinItem.action = #selector(togglePin)
        pinItem.target = self
        menu.addItem(pinItem)

        let resetItem = NSMenuItem(title: "Reset Record Position", action: #selector(resetRecordPosition), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit VYNL", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        statusItem.menu = menu

        store.nowPlaying.$info
            .sink { [weak self] info in
                self?.playItem.title = info?.isPlaying == true ? "Pause" : "Play"
            }
            .store(in: &cancellables)
        store.eq.$isEnabled
            .sink { [weak self] enabled in self?.eqItem.state = enabled ? .on : .off }
            .store(in: &cancellables)
        store.dock.$isPinned
            .sink { [weak self] pinned in self?.pinItem.state = pinned ? .on : .off }
            .store(in: &cancellables)
        store.dock.$showsLyrics
            .sink { [weak self] shows in self?.lyricsItem.state = shows ? .on : .off }
            .store(in: &cancellables)
    }

    @objc private func togglePlayer() { dock.toggle() }
    @objc private func playPause() { store.nowPlaying.togglePlayPause() }
    @objc private func nextTrack() { store.nowPlaying.nextTrack() }
    @objc private func previousTrack() { store.nowPlaying.previousTrack() }
    @objc private func toggleEQ() { store.eq.setEnabled(!store.eq.isEnabled) }
    @objc private func togglePin() { store.dock.isPinned.toggle() }
    @objc private func toggleLyrics() { store.dock.showsLyrics.toggle() }
    @objc private func resetRecordPosition() { dock.resetRecordPosition() }
}
