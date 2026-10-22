import AppKit

/// Where the record and the player go on a given screen.
///
/// Two optional tweaks, set from Terminal (then quit and reopen DevDock):
///   defaults write com.spencermarchant.vynl topOffset -float 8    # push it lower, e.g. under SketchyBar
///   defaults write com.spencermarchant.vynl side right            # top right instead of top left
enum DockGeometry {
    static let collapsedSize = NSSize(width: 60, height: 60)
    static let playerSize = NSSize(width: 440, height: 500)
    /// The lyrics column added to the left of the Now Playing tab.
    static let lyricsWidth: CGFloat = 300

    /// Native searches (SoundCloud with API keys, Apple Music) fit the player's width; websites
    /// (soundcloud.com, Spotify's web player) need room.
    static func expandedSize(mode: PanelMode, musicService: MusicService, soundCloudNative: Bool, showsLyrics: Bool) -> NSSize {
        let native = NSSize(width: 440, height: 560)
        let website = NSSize(width: 900, height: 640)
        switch mode {
        case .player:
            return showsLyrics ? NSSize(width: playerSize.width + lyricsWidth, height: playerSize.height) : playerSize
        case .settings:
            return playerSize
        case .music:
            switch musicService {
            case .spotify: return website
            case .soundCloud: return soundCloudNative ? native : website
            case .appleMusic: return native
            }
        }
    }
    static let margin: CGFloat = 12
    static let topGap: CGFloat = 6

    private static var topOffset: CGFloat {
        CGFloat(UserDefaults.standard.double(forKey: "topOffset"))
    }

    private static var onRightSide: Bool {
        UserDefaults.standard.string(forKey: "side") == "right"
    }

    static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// The highest y anything may reach: below the menu bar, and below the notch even when the
    /// menu bar auto-hides (visibleFrame then runs to the top of the screen).
    static func topEdge(of screen: NSScreen) -> CGFloat {
        let belowMenuBar = screen.visibleFrame.maxY
        let belowNotch = screen.frame.maxY - screen.safeAreaInsets.top
        return min(belowMenuBar, belowNotch) - topGap - topOffset
    }

    static func collapsedFrame(on screen: NSScreen) -> NSRect {
        let size = collapsedSize
        let visible = screen.visibleFrame
        let x = onRightSide ? visible.maxX - margin - size.width : visible.minX + margin
        return NSRect(x: x.rounded(), y: topEdge(of: screen) - size.height, width: size.width, height: size.height)
    }

    /// Where the record and player may go: the visible frame, capped below the menu bar and notch.
    static func usableFrame(of screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.minX,
            y: visible.minY,
            width: visible.width,
            height: max(topEdge(of: screen) - visible.minY, 0)
        )
    }

    /// The player opens from wherever the record sits, growing toward the side of the screen
    /// with more room, and stays on screen.
    static func expandedFrame(anchoredTo record: NSRect, size: NSSize, on screen: NSScreen) -> NSRect {
        let bounds = usableFrame(of: screen)
        let width = min(size.width, bounds.width - 2 * margin)
        let height = min(size.height, bounds.height - margin)
        let growsRight = record.midX <= bounds.midX
        let growsDown = record.midY >= bounds.midY
        var x = growsRight ? record.minX : record.maxX - width
        var y = growsDown ? record.maxY - height : record.minY
        x = min(max(x, bounds.minX + margin), bounds.maxX - margin - width)
        y = min(max(y, bounds.minY + margin), bounds.maxY - height)
        return NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
    }

    /// After a drag: keep the record fully on screen, and snap it to any edge it was dropped
    /// near, so it docks neatly into corners and along the top.
    static func settledRecordFrame(_ frame: NSRect, on screen: NSScreen) -> NSRect {
        let bounds = usableFrame(of: screen)
        let snapDistance: CGFloat = 28
        let minX = bounds.minX + margin
        let maxX = bounds.maxX - margin - frame.width
        let minY = bounds.minY + margin
        let maxY = bounds.maxY - frame.height
        var x = frame.minX
        var y = frame.minY
        if x - minX < snapDistance { x = minX }
        if maxX - x < snapDistance { x = maxX }
        if y - minY < snapDistance { y = minY }
        if maxY - y < snapDistance { y = maxY }
        x = min(max(x, minX), maxX)
        y = min(max(y, minY), maxY)
        return NSRect(x: x.rounded(), y: y.rounded(), width: frame.width, height: frame.height)
    }

    /// The screen a frame is mostly on (its center), or the nearest one.
    static func screen(containing frame: NSRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }) {
            return screen
        }
        return NSScreen.screens.min { a, b in
            hypot(center.x - a.frame.midX, center.y - a.frame.midY) < hypot(center.x - b.frame.midX, center.y - b.frame.midY)
        }
    }
}

/// Where you dragged the record, saved relative to its screen (as fractions of the usable area)
/// so it lands in the same spot after resolution or arrangement changes.
enum RecordPosition {
    private static let key = "recordPosition"

    private struct Saved: Codable {
        var displayID: UInt32
        var fractionX: Double
        var fractionY: Double
    }

    static func save(_ frame: NSRect, on screen: NSScreen) {
        guard let displayID = screen.displayID else { return }
        let bounds = DockGeometry.usableFrame(of: screen)
        let saved = Saved(
            displayID: displayID,
            fractionX: Double((frame.minX - bounds.minX) / max(bounds.width - frame.width, 1)),
            fractionY: Double((frame.minY - bounds.minY) / max(bounds.height - frame.height, 1))
        )
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// The saved frame, if that display is connected.
    static func savedFrame(size: NSSize) -> NSRect? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              let screen = NSScreen.screens.first(where: { $0.displayID == saved.displayID })
        else { return nil }
        let bounds = DockGeometry.usableFrame(of: screen)
        let x = bounds.minX + CGFloat(saved.fractionX) * max(bounds.width - size.width, 1)
        let y = bounds.minY + CGFloat(saved.fractionY) * max(bounds.height - size.height, 1)
        return DockGeometry.settledRecordFrame(NSRect(x: x, y: y, width: size.width, height: size.height), on: screen)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

extension NSScreen {
    /// Stable identifier for a display, used to find the record's screen again after changes.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
