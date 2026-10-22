import Foundation

/// VYNL used to be called DevDock (bundle ID com.spencermarchant.devdock). The first time VYNL
/// runs it copies DevDock's settings (theme, EQ, record position, lyrics) and moves its
/// SoundCloud keys folder, so nothing has to be set up again.
enum LegacyMigration {
    private static let oldBundleID = "com.spencermarchant.devdock"
    private static let doneKey = "migratedFromDevDock"

    static func run() {
        let defaults = UserDefaults.standard
        // Skipped when run from Xcode, which has no bundle ID.
        guard let bundleID = Bundle.main.bundleIdentifier, bundleID != oldBundleID,
              !defaults.bool(forKey: doneKey)
        else { return }

        if let old = defaults.persistentDomain(forName: oldBundleID) {
            var current = defaults.persistentDomain(forName: bundleID) ?? [:]
            for (key, value) in old where current[key] == nil {
                current[key] = value
            }
            defaults.setPersistentDomain(current, forName: bundleID)
        }
        moveSupportFolder()
        defaults.set(true, forKey: doneKey)
    }

    private static func moveSupportFolder() {
        let fileManager = FileManager.default
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let old = base.appendingPathComponent("DevDock", isDirectory: true)
        let new = base.appendingPathComponent("VYNL", isDirectory: true)
        guard fileManager.fileExists(atPath: old.path), !fileManager.fileExists(atPath: new.path) else { return }
        try? fileManager.moveItem(at: old, to: new)
    }
}
