import SwiftUI

/// The full player. Now Playing tab: big record, song info, tags, transport, seek bar, EQ, and
/// a lyrics column on the right (or left; mic button or Settings). The source tag picks which
/// app Now Playing follows.
/// Music tab: Spotify, SoundCloud or Apple Music, browsed and played inside VYNL.
/// Settings tab (sliders icon): which app to follow, lyrics, clear background, opacity, font, colors.
/// Only the parts that change often observe their own data, so the 30 fps spectrum and the
/// lyrics timer don't re-render the whole panel.
struct ExpandedPlayerView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var dock: DockModel
    @ObservedObject var nowPlaying: NowPlayingService
    @ObservedObject var output: OutputDeviceMonitor
    let eq: EQController
    let spectrum: SpectrumAnalyzer
    let soundCloud: SoundCloudService
    let soundCloudPlayer: SoundCloudPlayer
    let soundCloudWeb: MusicWebSession
    let spotifyWeb: MusicWebSession
    let appleMusic: AppleMusicSearch
    @ObservedObject var appearance: AppearanceSettings
    let lyrics: LyricsController
    let onCollapse: () -> Void

    var body: some View {
        // Fixed widths, aligned away from the lyrics: while the panel grows, the lyrics slide in
        // from their side instead of reflowing.
        HStack(spacing: 0) {
            if showsLyricsColumn && dock.lyricsSide == .left {
                lyricsColumn(leading: 18, trailing: 14)
                columnDivider
            }
            mainColumn
                .frame(width: showsLyricsColumn ? DockGeometry.playerSize.width : nil)
            if showsLyricsColumn && dock.lyricsSide == .right {
                columnDivider
                lyricsColumn(leading: 14, trailing: 18)
            }
        }
        // minWidth 0: take the panel's width even mid-animation, letting the extra clip.
        .frame(
            minWidth: 0,
            maxWidth: .infinity,
            minHeight: 0,
            maxHeight: .infinity,
            alignment: dock.lyricsSide == .left ? .topTrailing : .topLeading
        )
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.18))
        )
        .environment(\.colorScheme, .dark)
    }

    private var showsLyricsColumn: Bool {
        dock.mode == .player && dock.showsLyrics
    }

    private func lyricsColumn(leading: CGFloat, trailing: CGFloat) -> some View {
        LyricsPane(lyrics: lyrics)
            .padding(EdgeInsets(top: 16, leading: leading, bottom: 14, trailing: trailing))
            .frame(width: DockGeometry.lyricsWidth - 1)
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(width: 1)
            .padding(.vertical, 16)
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            topBar
            switch dock.mode {
            case .player:
                nowPlayingSection
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)
                EQSection(eq: eq, spectrum: spectrum)
                Spacer(minLength: 0)
            case .music:
                MusicPane(
                    dock: dock,
                    soundCloud: soundCloud,
                    soundCloudPlayer: soundCloudPlayer,
                    soundCloudWeb: soundCloudWeb,
                    spotifyWeb: spotifyWeb,
                    appleMusic: appleMusic
                )
            case .settings:
                AppearanceView(appearance: appearance, dock: dock, nowPlaying: nowPlaying)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Clear: nothing behind the content. Otherwise the blur with the tint at the chosen opacity.
    @ViewBuilder
    private var background: some View {
        if appearance.clearBackground {
            // Invisible, but not fully transparent: macOS sends clicks on fully transparent
            // pixels to the window behind, which would close the player.
            Color.black.opacity(0.02)
        } else {
            ZStack {
                VisualEffectBackground()
                theme.background.opacity(appearance.backgroundOpacity)
            }
        }
    }

    /// Tabs, pin and collapse. Clicking the bar's background collapses, like clicking the record.
    private var topBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                tab("Now Playing", mode: .player)
                tab("Music", mode: .music)
            }
            Spacer()
            Button {
                // From another tab, the mic goes back to Now Playing with lyrics showing.
                if dock.mode == .player {
                    dock.showsLyrics.toggle()
                } else {
                    dock.mode = .player
                    dock.showsLyrics = true
                }
            } label: {
                Image(systemName: "music.mic")
            }
            .buttonStyle(.plain)
            .foregroundStyle(showsLyricsColumn ? theme.accent : theme.textSecondary)
            .help(showsLyricsColumn ? "Hide lyrics" : "Show lyrics")
            Button {
                dock.mode = dock.mode == .settings ? .player : .settings
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.plain)
            .foregroundStyle(dock.mode == .settings ? theme.accent : theme.textSecondary)
            .help("Settings")
            Button {
                dock.isPinned.toggle()
            } label: {
                Image(systemName: dock.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.plain)
            .foregroundStyle(dock.isPinned ? theme.accent : theme.textSecondary)
            .help(dock.isPinned ? "Pinned: stays open when you click elsewhere" : "Collapses when you click elsewhere")
            Button(action: onCollapse) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.textSecondary)
            .help("Collapse (Esc or Control-Option-M)")
        }
        .font(theme.font(11, .semibold))
        .contentShape(Rectangle())
        .onTapGesture(perform: onCollapse)
    }

    private func tab(_ title: String, mode: PanelMode) -> some View {
        let selected = dock.mode == mode
        return Button {
            dock.mode = mode
        } label: {
            Text(title.uppercased())
                .font(theme.font(9, .semibold))
                .tracking(1.1)
                .foregroundStyle(selected ? theme.accent : theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(selected ? theme.accent.opacity(0.12) : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var nowPlayingSection: some View {
        let info = nowPlaying.info
        return VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                RecordView(
                    artwork: info?.artwork,
                    artworkKey: info?.artworkKey ?? -1,
                    isSpinning: info?.isPlaying ?? false,
                    accentHex: theme.accentHex
                )
                .frame(width: 118, height: 118)
                .opacity(info == nil ? 0.5 : 1)

                VStack(alignment: .leading, spacing: 5) {
                    MarqueeText(text: info?.title ?? "Nothing playing", isActive: info?.isPlaying ?? false)
                        .font(theme.font(15, .semibold))
                        .foregroundStyle(theme.textPrimary)
                    if info == nil && nowPlaying.followed != .auto {
                        followedEmptyState
                    } else {
                        Text(subtitle(for: info))
                            .font(theme.font(12))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        sourceChip
                        outputChip
                    }
                    .padding(.top, 2)
                    Spacer(minLength: 0)
                    TransportControls(nowPlaying: nowPlaying)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 118)
            }
            SeekBar(nowPlaying: nowPlaying)
        }
    }

    private func subtitle(for info: NowPlayingInfo?) -> String {
        guard let info else {
            switch nowPlaying.backend {
            case .spotify:
                return "Spotify only. Run scripts/fetch-adapter.sh to see other players too."
            case .starting, .adapter:
                return "Play something in Spotify, SoundCloud, Apple Music or any player."
            }
        }
        return [info.artist, info.album].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Where the song is playing. Click it to choose which app Now Playing follows; accent-colored
    /// while it's locked to one.
    private var sourceChip: some View {
        let followed = nowPlaying.followed
        let symbol: String
        let text: String
        if let info = nowPlaying.info {
            symbol = MediaSource.symbol(for: info.sourceBundleID)
            text = MediaSource.displayName(for: info.sourceBundleID)
        } else {
            symbol = followed.symbol
            text = followed.title
        }
        return Button {
            showFollowMenu()
        } label: {
            InfoChip(symbol: symbol, text: text, opensMenu: true, highlighted: followed != .auto)
        }
        .buttonStyle(.plain)
        .help(followed == .auto
            ? "Showing whatever's playing. Click to follow one app."
            : "Following \(followed.title) only. Click to change.")
    }

    /// The speakers or headphones playing now. Click it to switch to another output.
    private var outputChip: some View {
        Button {
            showOutputMenu()
        } label: {
            InfoChip(symbol: "hifispeaker.fill", text: output.deviceName, opensMenu: true)
        }
        .buttonStyle(.plain)
        .help("Click to choose where sound plays.")
    }

    private func showOutputMenu() {
        let current = output.deviceID
        let devices = AudioDevices.outputDevices()
        guard !devices.isEmpty else { return }
        PopupMenu.show(
            header: "Play sound through",
            items: devices.map { device in
                PopupMenu.Item(
                    title: AudioDevices.name(of: device) ?? "Unknown device",
                    isChecked: device == current
                ) {
                    if !AudioDevices.setDefaultOutputDevice(device) {
                        NSLog("VYNL: couldn't switch output to %@", AudioDevices.name(of: device) ?? "?")
                    }
                }
            }
        )
    }

    private func showFollowMenu() {
        let nowPlaying = self.nowPlaying
        PopupMenu.show(
            header: "Now Playing follows",
            items: PlayerSource.allCases.map { source in
                PopupMenu.Item(
                    title: source == .auto ? "Auto (whatever's playing)" : source.title,
                    isChecked: nowPlaying.followed == source
                ) {
                    nowPlaying.followed = source
                }
            }
        )
    }

    /// Following one app with nothing playing in it: say so, and offer to open it.
    private var followedEmptyState: some View {
        let followed = nowPlaying.followed
        return VStack(alignment: .leading, spacing: 3) {
            Text("Following \(followed.title).")
                .font(theme.font(12))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
            if let bundleID = followed.appBundleID, MusicPane.isInstalled(bundleID) {
                emptyStateButton("Open \(followed.appName)") {
                    nowPlaying.openFollowedApp()
                }
            } else if let service = followed.musicService {
                emptyStateButton("Find music in the Music tab") {
                    dock.musicService = service
                    dock.mode = .music
                }
            }
        }
    }

    private func emptyStateButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(theme.font(11, .semibold))
                .foregroundStyle(theme.accent)
        }
        .buttonStyle(.plain)
    }
}

struct TransportControls: View {
    @Environment(\.theme) private var theme
    @ObservedObject var nowPlaying: NowPlayingService

    var body: some View {
        HStack(spacing: 20) {
            control("backward.fill", size: 13) { nowPlaying.previousTrack() }
            control(nowPlaying.info?.isPlaying == true ? "pause.fill" : "play.fill", size: 20) {
                nowPlaying.togglePlayPause()
            }
            control("forward.fill", size: 13) { nowPlaying.nextTrack() }
        }
        .foregroundStyle(theme.textPrimary)
        .disabled(nowPlaying.info == nil)
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(theme.font(size, .semibold))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A draggable progress bar with elapsed and total time.
struct SeekBar: View {
    @Environment(\.theme) private var theme
    @ObservedObject var nowPlaying: NowPlayingService
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let info = nowPlaying.info
            let duration = info?.duration ?? 0
            let elapsed = info?.currentElapsed(at: context.date) ?? 0
            let fraction = dragFraction ?? (duration > 0 ? elapsed / duration : 0)
            VStack(spacing: 4) {
                GeometryReader { geometry in
                    let width = max(geometry.size.width, 1)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 4)
                        Capsule()
                            .fill(theme.accent)
                            .frame(width: max(4, width * fraction), height: 4)
                            .shadow(color: theme.accent.opacity(0.6), radius: 4)
                        Circle()
                            .fill(theme.accent)
                            .frame(width: 10, height: 10)
                            .shadow(color: theme.accent.opacity(0.8), radius: 5)
                            .offset(x: width * fraction - 5)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragFraction = min(max(Double(value.location.x / width), 0), 1)
                            }
                            .onEnded { value in
                                let target = min(max(Double(value.location.x / width), 0), 1)
                                dragFraction = nil
                                if duration > 0 {
                                    nowPlaying.seek(to: target * duration)
                                }
                            }
                    )
                }
                .frame(height: 12)
                HStack {
                    Text(formatTime(dragFraction.map { $0 * duration } ?? elapsed))
                    Spacer()
                    Text(duration > 0 ? formatTime(duration) : "--:--")
                }
                .font(theme.mono(10, .medium))
                .foregroundStyle(theme.textSecondary)
            }
            .disabled(duration <= 0)
        }
    }
}
