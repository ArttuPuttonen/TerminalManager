import AppKit
import ServiceManagement

enum Permissions {
    /// Opens System Settings → Privacy & Security → Automation, where you allow
    /// Terminal Manager to read and minimize Terminal's windows.
    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Launching at login is what lets the bar appear the moment you open Terminal.
    static var opensAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("TerminalManager: could not change login item: \(error)")
        }
    }

    /// Turn on "Open at Login" the first time the app runs; after that it's your choice.
    static func setUpLoginItemOnce() {
        // Only meaningful for the real .app bundle, not `swift run`.
        guard Bundle.main.bundleIdentifier != nil, !Settings.shared.didSetUpLoginItem else { return }
        Settings.shared.didSetUpLoginItem = true
        setOpensAtLogin(true)
    }
}
