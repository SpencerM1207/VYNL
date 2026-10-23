import Foundation
import ServiceManagement

/// Opens VYNL when you log in, through the system's Login Items (System Settings > General >
/// Login Items lists it too). Main thread only.
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var message: String?

    init() {
        refresh()
    }

    /// Re-reads the status, since it can also be changed in System Settings.
    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        message = status == .requiresApproval
            ? "Allow VYNL in System Settings > General > Login Items."
            : nil
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("VYNL: launch at login change failed: %@", error.localizedDescription)
        }
        refresh()
        if enabled && !isEnabled && message == nil {
            message = "Couldn't add VYNL to Login Items. Is it in Applications?"
        }
    }
}
