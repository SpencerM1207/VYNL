import AppKit
import SwiftUI

/// A small rounded tag: "Spotify", "JBL Tune 720BT".
struct InfoChip: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(theme.font(8, .semibold))
            Text(text)
                .lineLimit(1)
        }
        .font(theme.font(10, .medium))
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
    }
}

/// Real behind-window blur. `.active` keeps it blurred even when the panel isn't key.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// 03:28 style. Shows --:-- for unknown durations.
func formatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let total = Int(seconds.rounded(.down))
    return String(format: "%02d:%02d", total / 60, total % 60)
}
