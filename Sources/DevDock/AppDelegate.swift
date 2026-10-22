import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: PlayerStore?
    private var dock: DockController?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything reads settings.
        LegacyMigration.run()
        let store = PlayerStore()
        let dock = DockController(store: store)
        let statusItem = StatusItemController(dock: dock, store: store)
        dock.contextMenu = statusItem.menu
        store.start()
        dock.start()
        self.store = store
        self.dock = dock
        self.statusItem = statusItem
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Tear down the audio tap so other apps are never left muted.
        store?.stop()
    }
}
