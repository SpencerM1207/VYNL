import SwiftUI

/// The collapsed state: a small spinning record with a progress ring around it.
struct CollapsedRecordView: View {
    @ObservedObject var nowPlaying: NowPlayingService
    @ObservedObject var appearance: AppearanceSettings
    @Environment(\.theme) private var theme

    var body: some View {
        let info = nowPlaying.info
        ZStack {
            // A faint backdrop so the record reads on any wallpaper. In clear mode it's invisible
            // but still there, so clicks between the ring and the record don't fall through.
            Circle()
                .fill(appearance.clearBackground ? Color.black.opacity(0.02) : theme.background.opacity(0.45))
            ProgressRing(info: info)
                .padding(1)
            RecordView(
                artwork: info?.artwork,
                artworkKey: info?.artworkKey ?? -1,
                isSpinning: info?.isPlaying ?? false,
                accentHex: theme.accentHex
            )
            .padding(5)
            .opacity(info == nil ? 0.45 : 1)
        }
        .opacity(appearance.recordOpacity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Circle())
        .help(info.map { $0.artist.isEmpty ? $0.title : "\($0.title) - \($0.artist)" } ?? "Nothing playing")
    }
}

/// Song progress as a thin glowing ring.
struct ProgressRing: View {
    @Environment(\.theme) private var theme
    let info: NowPlayingInfo?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let progress = Self.progress(of: info, at: context.date)
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: theme.accent.opacity(0.6), radius: 3)
            }
        }
    }

    private static func progress(of info: NowPlayingInfo?, at date: Date) -> CGFloat {
        guard let info, info.duration > 0 else { return 0 }
        return CGFloat(min(max(info.currentElapsed(at: date) / info.duration, 0), 1))
    }
}
