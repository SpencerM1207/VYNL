import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Owns both panels and the collapsed/expanded state machine.
///
/// Expanding: the player panel starts at the record's frame, becomes key, and grows to full
/// size while the record hides. Collapsing: it shrinks back, orders out (keyboard focus returns
/// to the app you were in), and the record reappears. The record goes wherever you drag it
/// (remembered in RecordPosition); the player always opens from there.
@MainActor
final class DockController: NSObject {
    private enum Phase {
        case collapsed, expanding, expanded, collapsing
    }

    private static let animationDuration: TimeInterval = 0.22

    /// Shown when you right-click the record. Set by AppDelegate.
    var contextMenu: NSMenu?

    private let store: PlayerStore
    private let recordPanel: DockPanel
    private let playerPanel: ExpandedPanel
    private var phase: Phase = .collapsed
    private var hotKey: GlobalHotKey?
    private var cancellables = Set<AnyCancellable>()

    init(store: PlayerStore) {
        self.store = store
        recordPanel = DockPanel(
            contentRect: NSRect(origin: .zero, size: DockGeometry.collapsedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        playerPanel = ExpandedPanel(
            contentRect: NSRect(origin: .zero, size: DockGeometry.playerSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        recordPanel.applyFloatingStyle()
        recordPanel.hasShadow = false // the record draws its own glow
        playerPanel.applyFloatingStyle()

        let record = CollapsedRecordView(nowPlaying: store.nowPlaying, appearance: store.appearance)
        let recordHost = FirstMouseHostingView(rootView: ThemedRoot(appearance: store.appearance, content: record))
        recordHost.sizingOptions = []
        recordPanel.contentView = recordHost

        let player = ExpandedPlayerView(
            dock: store.dock,
            nowPlaying: store.nowPlaying,
            output: store.output,
            eq: store.eq,
            spectrum: store.spectrum,
            soundCloud: store.soundCloud,
            soundCloudPlayer: store.soundCloudPlayer,
            soundCloudWeb: store.soundCloudWeb,
            appearance: store.appearance,
            lyrics: store.lyrics,
            onCollapse: { [weak self] in self?.collapse() }
        )
        let playerHost = FirstMouseHostingView(rootView: ThemedRoot(appearance: store.appearance, content: player))
        playerHost.sizingOptions = []
        playerPanel.contentView = playerHost
    }

    func start() {
        recordPanel.onClick = { [weak self] in self?.expand() }
        recordPanel.onRightClick = { [weak self] event in self?.showContextMenu(for: event) }
        recordPanel.onDragEnded = { [weak self] in self?.recordDragEnded() }
        playerPanel.onEscape = { [weak self] in self?.collapse() }

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(playerPanelDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: playerPanel
        )
        center.addObserver(
            self,
            selector: #selector(screensChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        hotKey = GlobalHotKey(
            keyCode: GlobalHotKey.toggleKeyCode,
            modifiers: GlobalHotKey.toggleModifiers
        ) { [weak self] in
            self?.hotKeyPressed()
        }
        if hotKey == nil {
            NSLog("VYNL: couldn't register Control-Option-M. Another app may already use it.")
        }

        // Switching tabs, showing lyrics, or adding SoundCloud keys resizes the open player.
        // @Published fires before the value changes, so resize on the next turn of the run loop.
        store.dock.$mode
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.resizeIfExpanded() } }
            .store(in: &cancellables)
        store.dock.$showsLyrics
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.resizeIfExpanded() } }
            .store(in: &cancellables)
        store.soundCloud.$hasCredentials
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.resizeIfExpanded() } }
            .store(in: &cancellables)
        // When a sign-in popup closes, hand keyboard focus back to the player.
        store.dock.$holdOpen
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.phase == .expanded else { return }
                    self.playerPanel.makeKeyAndOrderFront(nil)
                }
            }
            .store(in: &cancellables)

        placeRecord()
        recordPanel.orderFrontRegardless()
    }

    func toggle() {
        switch phase {
        case .collapsed:
            expand()
        case .expanded:
            collapse()
        case .expanding, .collapsing:
            break
        }
    }

    func expand() {
        guard phase == .collapsed, let screen = recordScreen else { return }
        phase = .expanding

        let start = recordPanel.frame
        let end = DockGeometry.expandedFrame(anchoredTo: start, size: expandedSize, on: screen)

        playerPanel.alphaValue = 0
        playerPanel.setFrame(start, display: false)
        playerPanel.makeKeyAndOrderFront(nil)
        recordPanel.orderOut(nil)
        store.dock.isExpanded = true

        animate(playerPanel, to: end, alpha: 1) { [weak self] in
            guard let self else { return }
            self.phase = .expanded
            self.playerPanel.invalidateShadow()
        }
    }

    func collapse() {
        guard phase == .expanded else { return }
        phase = .collapsing

        // The record keeps its frame while hidden, so shrink back into it.
        let target = recordPanel.frame

        animate(playerPanel, to: target, alpha: 0) { [weak self] in
            guard let self else { return }
            self.playerPanel.orderOut(nil)
            self.recordPanel.orderFrontRegardless()
            self.store.dock.isExpanded = false
            self.phase = .collapsed
        }
    }

    /// Back to the default spot under the menu bar (top left, or top right with the `side` default).
    func resetRecordPosition() {
        RecordPosition.clear()
        placeRecord(animated: phase == .collapsed)
    }

    // MARK: - Private

    private var recordScreen: NSScreen? {
        DockGeometry.screen(containing: recordPanel.frame)
    }

    /// The saved spot if its display is connected, otherwise the default corner.
    private func placeRecord(animated: Bool = false) {
        let frame: NSRect
        if let saved = RecordPosition.savedFrame(size: DockGeometry.collapsedSize) {
            frame = saved
        } else if let screen = DockGeometry.screenUnderMouse() {
            frame = DockGeometry.collapsedFrame(on: screen)
        } else {
            return
        }
        if animated {
            animate(recordPanel, to: frame, alpha: 1) {}
        } else {
            recordPanel.setFrame(frame, display: true)
        }
    }

    /// Keep the dropped record on screen, snap it to a nearby edge, and remember the spot.
    private func recordDragEnded() {
        guard let screen = recordScreen else { return }
        let settled = DockGeometry.settledRecordFrame(recordPanel.frame, on: screen)
        RecordPosition.save(settled, on: screen)
        if settled != recordPanel.frame {
            animate(recordPanel, to: settled, alpha: 1, duration: 0.16) {}
        }
    }

    private var expandedSize: NSSize {
        DockGeometry.expandedSize(
            mode: store.dock.mode,
            soundCloudNative: store.soundCloud.hasCredentials,
            showsLyrics: store.dock.showsLyrics
        )
    }

    private func resizeIfExpanded() {
        guard phase == .expanded, let screen = recordScreen else { return }
        let target = DockGeometry.expandedFrame(anchoredTo: recordPanel.frame, size: expandedSize, on: screen)
        guard target != playerPanel.frame else { return }
        animate(playerPanel, to: target, alpha: 1) { [weak self] in
            self?.playerPanel.invalidateShadow()
        }
    }

    /// Open but unfocused (pinned, and you clicked elsewhere): the hotkey focuses it.
    /// Otherwise it toggles.
    private func hotKeyPressed() {
        if phase == .expanded && !playerPanel.isKeyWindow {
            playerPanel.makeKeyAndOrderFront(nil)
        } else {
            toggle()
        }
    }

    private func animate(
        _ panel: NSPanel,
        to frame: NSRect,
        alpha: CGFloat,
        duration: TimeInterval? = nil,
        completion: @escaping @MainActor () -> Void
    ) {
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? 0
            : (duration ?? Self.animationDuration)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = alpha
        }, completionHandler: {
            Task { @MainActor in completion() }
        })
    }

    @objc private func playerPanelDidResignKey(_ notification: Notification) {
        guard phase == .expanded, !store.dock.isPinned, !store.dock.holdOpen else { return }
        collapse()
    }

    @objc private func screensChanged(_ notification: Notification) {
        switch phase {
        case .collapsed:
            placeRecord()
        case .expanded:
            placeRecord()
            guard let screen = recordScreen else { return }
            playerPanel.setFrame(
                DockGeometry.expandedFrame(anchoredTo: recordPanel.frame, size: expandedSize, on: screen),
                display: true
            )
            playerPanel.invalidateShadow()
        case .expanding, .collapsing:
            break
        }
    }

    private func showContextMenu(for event: NSEvent) {
        guard let menu = contextMenu, let view = recordPanel.contentView else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
}
