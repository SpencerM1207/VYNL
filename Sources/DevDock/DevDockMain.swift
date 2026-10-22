import AppKit

@main
enum DevDockMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // No Dock icon and no Cmd-Tab entry. The bundled app also sets LSUIElement in Info.plist,
        // but setting it here means `swift run` behaves the same way.
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
