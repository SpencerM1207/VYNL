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
    let soundCloudWeb = SoundCloudWebSession()
    let appearance = AppearanceSettings()
    let lyrics: LyricsController

    private var cancellables = Set<AnyCancellable>()

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
        // DevDock's own SoundCloud playback shows on the record and takes the controls.
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
        let dock = self.dock
        soundCloudWeb.onPopupChange = { [weak dock] open in
            dock?.holdOpen = open
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
}
