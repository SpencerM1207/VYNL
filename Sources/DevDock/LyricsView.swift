import AppKit
import SwiftUI

/// The lyrics column beside the Now Playing tab, styled after Spotify's lyrics view:
/// the sung line lights up, the list glides to keep it in view, clicking a line jumps the song
/// there, and scrolling yourself pauses the follow until you come back (or 5 s pass).
/// The timer button fixes the timing: tap the line you're hearing, or nudge earlier/later.
struct LyricsPane: View {
    @Environment(\.theme) private var theme
    @ObservedObject var lyrics: LyricsController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if lyrics.isAdjusting && !lyrics.followedLines.isEmpty {
                TimingBar(lyrics: lyrics)
                    .transition(.opacity)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsCredit {
                Text("Lyrics from LRCLIB")
                    .font(theme.font(9, .medium))
                    .foregroundStyle(theme.textSecondary.opacity(0.7))
            }
        }
        .animation(.easeOut(duration: 0.15), value: lyrics.isAdjusting)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("LYRICS")
                .font(theme.font(9, .semibold))
                .tracking(1.1)
                .foregroundStyle(theme.textSecondary)
            Spacer()
            if !lyrics.followedLines.isEmpty {
                Button {
                    lyrics.isAdjusting.toggle()
                } label: {
                    Image(systemName: "timer")
                        .font(theme.font(11, .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(lyrics.isAdjusting || lyrics.hasCustomTiming ? theme.accent : theme.textSecondary)
                .help("Fix the timing")
            }
        }
        .padding(.vertical, 4) // lines up with the tabs
    }

    @ViewBuilder
    private var content: some View {
        switch lyrics.status {
        case .idle:
            LyricsMessage(
                symbol: "music.mic",
                title: "Lyrics show up here",
                detail: "Play a song and its words will follow along."
            )
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Finding lyrics…")
                    .font(theme.font(11))
                    .foregroundStyle(theme.textSecondary)
            }
        case .notFound:
            if lyrics.transcribesMissingLyrics {
                TranscriptView(transcriber: lyrics.transcriber)
                    .id(lyrics.contentID)
            } else {
                LyricsMessage(
                    symbol: "text.quote",
                    title: "No lyrics for this one",
                    detail: "LRCLIB doesn't have this song yet."
                )
            }
        case .failed(let reason):
            LyricsMessage(
                symbol: "exclamationmark.triangle",
                title: "Couldn't load lyrics",
                detail: reason,
                actionTitle: "Try Again"
            ) {
                lyrics.retry()
            }
        case .loaded(.instrumental):
            LyricsMessage(
                symbol: "music.note",
                title: "Instrumental",
                detail: "No words in this one. Enjoy the music."
            )
        case .loaded(.plain(let lines, otherVersion: let otherVersion)):
            if let otherVersion, lyrics.hasCustomTiming {
                SyncedLyricsView(lyrics: lyrics, lines: otherVersion)
                    .id(lyrics.contentID + "\nsynced")
            } else if let otherVersion {
                OtherVersionView(lyrics: lyrics, lines: otherVersion)
                    .id(lyrics.contentID)
            } else {
                PlainLyricsView(lines: lines)
                    .id(lyrics.contentID)
            }
        case .loaded(.synced(let lines)):
            SyncedLyricsView(lyrics: lyrics, lines: lines)
                .id(lyrics.contentID)
        }
    }

    private var showsCredit: Bool {
        if case .loaded = lyrics.status {
            return true
        }
        return false
    }
}

/// Fades lines out at the top and bottom edges, like Spotify.
private var lyricsFade: LinearGradient {
    LinearGradient(
        stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.1),
            .init(color: .black, location: 0.86),
            .init(color: .clear, location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}

private struct SyncedLyricsView: View {
    private enum LineState {
        case past, current, upcoming
    }

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var lyrics: LyricsController
    let lines: [LyricLine]

    @State private var following = true
    @State private var scrollGeneration = 0
    @State private var hoveredLine: Int?

    /// Where the sung line sits: a third of the way down, like Spotify.
    private static let anchor = UnitPoint(x: 0.5, y: 0.32)
    private static let resumeDelay: UInt64 = 5_000_000_000

    var body: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 14) {
                            // Room above and below so the first and last lines can reach the anchor.
                            Color.clear.frame(height: geometry.size.height * 0.3)
                            ForEach(lines) { line in
                                row(line)
                                    .id(line.id)
                            }
                            Color.clear.frame(height: geometry.size.height * 0.62)
                        }
                        .padding(.trailing, 4)
                    }
                    .background(ScrollWheelWatcher { userScrolled() })
                    .onAppear {
                        scroll(proxy, animated: false)
                    }
                    .onChange(of: lyrics.currentIndex) {
                        if following {
                            scroll(proxy, animated: true)
                        }
                    }
                    .onChange(of: following) { _, isFollowing in
                        if isFollowing {
                            scroll(proxy, animated: true)
                        }
                    }
                }
            }
            .mask { lyricsFade }

            if !following {
                Button {
                    following = true
                } label: {
                    Label("Back to current line", systemImage: "arrow.uturn.backward")
                        .font(theme.font(10, .semibold))
                        .foregroundStyle(theme.background)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(theme.accent))
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: following)
    }

    @ViewBuilder
    private func row(_ line: LyricLine) -> some View {
        let state = lineState(line)
        if line.isBreak {
            BreakDots(
                lyrics: lyrics,
                isActive: state == .current,
                isPast: state == .past,
                start: line.time,
                end: breakEnd(after: line)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { tapped(line) }
        } else {
            let hovered = hoveredLine == line.id
            Text(line.text)
                .font(theme.font(18, .bold))
                .foregroundStyle(color(for: state, hovered: hovered))
                .shadow(color: state == .current ? theme.accent.opacity(0.4) : .clear, radius: 10)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside {
                        hoveredLine = line.id
                    } else if hoveredLine == line.id {
                        hoveredLine = nil
                    }
                }
                .onTapGesture { tapped(line) }
                .animation(.easeOut(duration: 0.25), value: state)
        }
    }

    /// Normally a tap seeks there; while fixing the timing it means "this is what I hear now".
    private func tapped(_ line: LyricLine) {
        if lyrics.isAdjusting {
            lyrics.sync(to: line)
            following = true
        } else {
            jump(to: line)
        }
    }

    private func lineState(_ line: LyricLine) -> LineState {
        guard let current = lyrics.currentIndex else { return .upcoming }
        if line.id == current { return .current }
        return line.id < current ? .past : .upcoming
    }

    private func color(for state: LineState, hovered: Bool) -> Color {
        switch state {
        case .current: return theme.text
        case .past: return theme.text.opacity(hovered ? 0.8 : 0.5)
        case .upcoming: return theme.text.opacity(hovered ? 0.7 : 0.26)
        }
    }

    /// A break lasts until the next line, or the end of the song for an outro.
    private func breakEnd(after line: LyricLine) -> TimeInterval {
        let next = line.id + 1
        if next < lines.count {
            return lines[next].time
        }
        // Lyric time runs `offset` behind the song.
        return max(lyrics.duration - lyrics.offset, line.time + 4)
    }

    private func jump(to line: LyricLine) {
        lyrics.seek(to: line)
        following = true
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let target = lyrics.currentIndex ?? lines.first?.id else { return }
        if animated && !reduceMotion {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.9)) {
                proxy.scrollTo(target, anchor: Self.anchor)
            }
        } else {
            proxy.scrollTo(target, anchor: Self.anchor)
        }
    }

    /// Scrolling yourself stops the follow; it comes back 5 s after the last scroll.
    private func userScrolled() {
        following = false
        scrollGeneration += 1
        let generation = scrollGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.resumeDelay)
            if scrollGeneration == generation {
                following = true
            }
        }
    }
}

/// Three dots for an instrumental break. While it's the current spot they fill one by one over
/// the break and gently pulse, so you can see when the singing comes back.
private struct BreakDots: View {
    @Environment(\.theme) private var theme
    @ObservedObject var lyrics: LyricsController
    let isActive: Bool
    let isPast: Bool
    let start: TimeInterval
    let end: TimeInterval

    var body: some View {
        if isActive {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !lyrics.isPlaying)) { context in
                let length = max(end - start, 0.1)
                let progress = min(max((lyrics.position(at: context.date) - start) / length, 0), 1)
                let seconds = context.date.timeIntervalSinceReferenceDate
                let pulse = 1 + 0.12 * sin(seconds * 2 * Double.pi / 1.6)
                dots(progress: progress)
                    .scaleEffect(lyrics.isPlaying ? pulse : 1, anchor: .leading)
            }
        } else {
            dots(progress: isPast ? 1 : 0)
                .opacity(0.6)
        }
    }

    private func dots(progress: Double) -> some View {
        HStack(spacing: 7) {
            ForEach(0..<3, id: \.self) { index in
                let fill = min(max(progress * 3 - Double(index), 0), 1)
                Circle()
                    .fill(theme.text.opacity(0.25 + 0.75 * fill))
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 6)
    }
}

/// Lyrics without timing: plain text to read along, with a note that they aren't synced.
private struct PlainLyricsView: View {
    @Environment(\.theme) private var theme
    let lines: [String]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                Text("LRCLIB only has these words without timing, so they don't follow along.")
                    .font(theme.font(10, .medium))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.bottom, 6)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if line.isEmpty {
                        Color.clear.frame(height: 6)
                    } else {
                        Text(line)
                            .font(theme.font(16, .bold))
                            .foregroundStyle(theme.text.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 18)
            .padding(.trailing, 4)
        }
        .mask { lyricsFade }
    }
}

/// Under the header while fixing the timing: nudge buttons, the current shift, Reset and Done.
private struct TimingBar: View {
    @Environment(\.theme) private var theme
    @ObservedObject var lyrics: LyricsController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tap the line you're hearing, or nudge:")
                .font(theme.font(10, .medium))
                .foregroundStyle(theme.textSecondary)
            HStack(spacing: 6) {
                pill(systemImage: "minus", help: "Show lyrics earlier") { lyrics.nudge(by: -0.5) }
                Text(String(format: "%+.1f s", lyrics.offset))
                    .font(theme.mono(10, .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(minWidth: 50)
                pill(systemImage: "plus", help: "Show lyrics later") { lyrics.nudge(by: 0.5) }
                Spacer(minLength: 4)
                if lyrics.hasCustomTiming {
                    pill(title: "Reset", help: "Back to the original timing") { lyrics.resetTiming() }
                }
                pill(title: "Done", help: "Close the timing controls", prominent: true) { lyrics.isAdjusting = false }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    private func pill(
        title: String? = nil,
        systemImage: String? = nil,
        help: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                } else {
                    Text(title ?? "")
                }
            }
            .font(theme.font(10, .semibold))
            .foregroundStyle(prominent ? theme.accent : theme.textPrimary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(prominent ? theme.accent.opacity(0.14) : Color.white.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Lyrics timed for another version of the song (the original of an extended mix, say): the
/// right words, but the times would be off. One tap on the line you're hearing syncs them.
private struct OtherVersionView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var lyrics: LyricsController
    let lines: [LyricLine]

    @State private var hoveredLine: Int?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("These lyrics are timed for another version of the song.")
                        .foregroundStyle(theme.textSecondary)
                    Text("Tap the line you're hearing to sync them.")
                        .foregroundStyle(theme.accent)
                }
                .font(theme.font(10, .medium))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)
                ForEach(lines.filter { !$0.isBreak }) { line in
                    Text(line.text)
                        .font(theme.font(16, .bold))
                        .foregroundStyle(theme.text.opacity(hoveredLine == line.id ? 1 : 0.75))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside {
                                hoveredLine = line.id
                            } else if hoveredLine == line.id {
                                hoveredLine = nil
                            }
                        }
                        .onTapGesture {
                            lyrics.sync(to: line)
                            lyrics.isAdjusting = true // leave the nudge buttons up for fine-tuning
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 18)
            .padding(.trailing, 4)
        }
        .mask { lyricsFade }
    }
}

/// Live captions for songs LRCLIB doesn't have: finished lines dimmed, the line being heard
/// bright at the bottom, with a note that it's VYNL's guess.
private struct TranscriptView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var transcriber: LyricsTranscriber

    var body: some View {
        switch transcriber.state {
        case .unavailable(let reason):
            LyricsMessage(symbol: "text.quote", title: "No lyrics for this one", detail: reason)
        case .idle:
            LyricsMessage(
                symbol: "waveform",
                title: "Not on LRCLIB",
                detail: "VYNL will write down what it hears while this column is open."
            )
        case .preparing(let message):
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(message)
                    .font(theme.font(11))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 12)
        case .listening:
            listening
        }
    }

    private var listening: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "waveform")
                    .foregroundStyle(theme.accent)
                Text("Not on LRCLIB, so VYNL is writing down what it hears. Expect mistakes.")
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(theme.font(10, .medium))
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        Color.clear.frame(height: 12)
                        ForEach(Array(transcriber.lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(theme.font(16, .bold))
                                .foregroundStyle(theme.text.opacity(0.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !transcriber.partial.isEmpty {
                            Text(transcriber.partial)
                                .font(theme.font(18, .bold))
                                .foregroundStyle(theme.text)
                                .shadow(color: theme.accent.opacity(0.4), radius: 10)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if transcriber.lines.isEmpty {
                            Text(transcriber.hearsAudio ? "Listening…" : "No sound is reaching VYNL. Allow it in System Settings > Privacy & Security > Screen & System Audio Recording.")
                                .font(theme.font(transcriber.hearsAudio ? 16 : 11, .semibold))
                                .foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Color.clear.frame(height: 24).id(Self.bottomID)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 4)
                }
                .mask { lyricsFade }
                .onAppear {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
                .onChange(of: transcriber.lines.count) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                }
                .onChange(of: transcriber.partial) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
        }
    }

    private static let bottomID = "transcript-end"
}

/// A centered icon, title and hint for the states without lyrics to show.
private struct LyricsMessage: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let title: String
    let detail: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(theme.font(22))
                .foregroundStyle(theme.accent.opacity(0.85))
            Text(title)
                .font(theme.font(13, .semibold))
                .foregroundStyle(theme.textPrimary)
            Text(detail)
                .font(theme.font(11))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(theme.font(11, .semibold))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(theme.accent.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Reports wheel and trackpad scrolling over this view. Code-driven scrolling sends no wheel
/// events, so this tells your scrolling apart from the auto-follow.
private struct ScrollWheelWatcher: NSViewRepresentable {
    let onScroll: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        context.coordinator.view = view
        context.coordinator.onScroll = onScroll
        context.coordinator.start()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var onScroll: (() -> Void)?
        private var monitor: Any?

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handle(event)
                }
                return event
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard let view, let window = view.window, event.window === window else { return }
            let point = view.convert(event.locationInWindow, from: nil)
            if view.bounds.contains(point) {
                onScroll?()
            }
        }
    }

    /// Sits behind the lyrics without catching clicks.
    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
