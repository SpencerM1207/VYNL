import AppKit
import SwiftUI

extension NSPanel {
    /// Floats above normal windows on every Space, including over fullscreen apps,
    /// and stays out of Cmd-` window cycling and Mission Control.
    func applyFloatingStyle() {
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
}

/// The collapsed record. It can never become key, so clicking it leaves keyboard focus in the
/// app you're using. Drag it to move it anywhere; a click without movement opens the player.
final class DockPanel: NSPanel {
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    /// Called when a drag finishes, so the controller can snap and save the position.
    var onDragEnded: (() -> Void)?

    /// Movement (in points) before a press counts as a drag rather than a click.
    private static let dragThreshold: CGFloat = 3

    private var pressLocation: NSPoint?
    private var pressOrigin: NSPoint = .zero
    private var isDragging = false

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // Screen coordinates, because the window itself moves during the drag.
            pressLocation = NSEvent.mouseLocation
            pressOrigin = frame.origin
            isDragging = false
            super.sendEvent(event)
        case .leftMouseDragged:
            guard let start = pressLocation else {
                super.sendEvent(event)
                return
            }
            let now = NSEvent.mouseLocation
            let dx = now.x - start.x
            let dy = now.y - start.y
            if !isDragging {
                guard hypot(dx, dy) >= Self.dragThreshold else { return }
                isDragging = true
                NSCursor.closedHand.push()
            }
            setFrameOrigin(NSPoint(x: pressOrigin.x + dx, y: pressOrigin.y + dy))
        case .leftMouseUp:
            super.sendEvent(event)
            let wasDragging = isDragging
            pressLocation = nil
            isDragging = false
            if wasDragging {
                NSCursor.pop()
                onDragEnded?()
            } else {
                onClick?()
            }
        case .rightMouseDown:
            super.sendEvent(event)
            onRightClick?(event)
        default:
            super.sendEvent(event)
        }
    }
}

/// The full player. Unlike the record it can become key, so Esc and future text fields work.
/// Borderless panels return false from canBecomeKey by default, which would drop all keys.
final class ExpandedPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, !focusedViewWantsEscape { // 53 = Esc
            onEscape?()
            return
        }
        super.sendEvent(event)
    }

    /// DevDock has no menu bar, which is where Cut/Copy/Paste shortcuts normally come from.
    /// Send them to the focused field directly.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command || flags == [.command, .shift],
           let key = event.charactersIgnoringModifiers?.lowercased() {
            let action: Selector?
            switch (key, flags.contains(.shift)) {
            case ("x", false): action = #selector(NSText.cut(_:))
            case ("c", false): action = #selector(NSText.copy(_:))
            case ("v", false): action = #selector(NSText.paste(_:))
            case ("a", false): action = #selector(NSText.selectAll(_:))
            case ("z", false): action = Selector(("undo:"))
            case ("z", true): action = Selector(("redo:"))
            default: action = nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// A text field being edited keeps Esc for itself.
    private var focusedViewWantsEscape: Bool {
        firstResponder is NSText
    }
}

/// Lets the first click on a panel that isn't key go straight to the SwiftUI content.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
