import AppKit
import SwiftUI

/// A small rounded tag: "Spotify", "JBL Tune 720BT".
struct InfoChip: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let text: String
    /// A small chevron, for chips that open a menu.
    var opensMenu = false
    /// Accent-colored, e.g. while Now Playing is locked to one app.
    var highlighted = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(theme.font(8, .semibold))
            Text(text)
                .lineLimit(1)
            if opensMenu {
                Image(systemName: "chevron.down")
                    .font(theme.font(7, .bold))
                    .opacity(0.7)
            }
        }
        .font(theme.font(10, .medium))
        .foregroundStyle(highlighted ? theme.accent : theme.textSecondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(highlighted ? theme.accent.opacity(0.12) : Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(highlighted ? theme.accent.opacity(0.3) : Color.white.opacity(0.08)))
        .contentShape(Capsule())
    }
}

/// A plain AppKit menu at the mouse. SwiftUI's Menu flattens custom labels on macOS, and a
/// popover would take key status and close the player; a menu does neither.
@MainActor
enum PopupMenu {
    struct Item {
        let title: String
        let isChecked: Bool
        let action: () -> Void
    }

    static func show(header: String?, items: [Item]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let header {
            menu.addItem(NSMenuItem.sectionHeader(title: header))
        }
        for item in items {
            let menuItem = ClosureMenuItem(title: item.title, handler: item.action)
            menuItem.state = item.isChecked ? .on : .off
            menu.addItem(menuItem)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(ClosureMenuItem.fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func fire() {
        handler()
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
