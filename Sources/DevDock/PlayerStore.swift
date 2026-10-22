import Combine
import Foundation

/// Owns every service and wires them together.
@MainActor
final class PlayerStore {
    let dock = DockModel()
    let output: OutputDeviceMonitor
    let nowPlaying: NowPlayingService
    let eq: EQController
    let spectrum: SpectrumAnalyzer
    let soundCloud = SoundCloudService()
    let soundCloudPlayer = SoundCloudPlayer()
    let soundCloudWeb = MusicWebSession.soundCloud()
    let spotifyWeb = MusicWebSession.spotify()
    let appleMusic = AppleMusicSearch()
    let appearance = AppearanceSettings()
    let lyrics: LyricsController

    private var cancellables = Set<AnyCancellable>()
    private var openPopups: Set<String> = []

    init() {
        let output = OutputDeviceMonitor()
        let nowPlaying = NowPlayingService()
        let eq = EQController(output: output)
        self.output = output
        self.nowPlaying = nowPlaying
        self.eq = eq
        spectrum = SpectrumAnalyzer(eq: eq)
        lyrics = LyricsController(nowPlaying: nowPlaying)
        eq.isMusicPlaying = { [weak nowPlaying] in
            nowPlaying?.info?.isPlaying ?? false
        }
    }

    func start() {
        // VYNL's own SoundCloud playback shows on the record and takes the controls.
        let nowPlaying = self.nowPlaying
        let player = soundCloudPlayer
        player.onInfoChange = { [weak nowPlaying] info in
            nowPlaying?.setInternal(info)
        }
        player.willStartPlayback = { [weak nowPlaying] in
            nowPlaying?.pauseExternalPlayback()
        }
        nowPlaying.onInternalCommand = { [weak player] command in
            player?.handle(command)
        }
        // VYNL's web players: label their sound and press their buttons.
        nowPlaying.onOwnWebAudio = { [weak self] in
            self?.identifyOwnWebAudio()
        }
        nowPlaying.onWebCommand = { [weak self] service, command in
            guard let self else { return }
            (service == .spotify ? self.spotifyWeb : self.soundCloudWeb).perform(command)
        }
        // A sign-in popup from either site keeps the player open behind it.
        soundCloudWeb.onPopupChange = { [weak self] open in
            self?.popupChanged("soundcloud", open: open)
        }
        spotifyWeb.onPopupChange = { [weak self] open in
            self?.popupChanged("spotify", open: open)
        }

        output.start()
        lyrics.start(dock: dock)
        nowPlaying.start()
        eq.start()
        // The spectrum only runs while the player is open and the EQ engine is running.
        dock.$isExpanded
            .combineLatest(eq.$isRunning)
            .sink { [weak self] expanded, running in
                self?.spectrum.setActive(expanded && running)
            }
            .store(in: &cancellables)
    }

    func stop() {
        eq.shutdown()
        nowPlaying.stop()
    }

    // MARK: - Private

    private func popupChanged(_ site: String, open: Bool) {
        if open {
            openPopups.insert(site)
        } else {
            openPopups.remove(site)
        }
        dock.holdOpen = !openPopups.isEmpty
    }

    /// macOS reports all of VYNL's web audio under one name. Ask the two sites which one is
    /// playing; if neither is (paused), keep the last answer.
    private func identifyOwnWebAudio() {
        Task { [weak self] in
            guard let self else { return }
            let spotifyPlaying = await self.spotifyWeb.isPlaying()
            let soundCloudPlaying = await self.soundCloudWeb.isPlaying()
            if spotifyPlaying && !soundCloudPlaying {
                self.nowPlaying.ownWebSource = .spotify
            } else if soundCloudPlaying {
                self.nowPlaying.ownWebSource = .soundCloud
            }
        }
    }
}
