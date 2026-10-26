import AppKit
import UserNotifications

/// Posts macOS notifications ("Terminal 2 needs you") and plays a sound.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Called when you click a notification, with the Terminal window id.
    var onOpen: ((Int) -> Void)?

    /// UNUserNotificationCenter crashes when the binary is not inside an .app bundle
    /// (e.g. `swift run`), so only use it when we have a bundle identifier.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func setUp() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(for window: ManagedWindow, title: String, body: String) {
        playSound(for: window.state)
        guard Settings.shared.notifications, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["window": window.id]
        content.threadIdentifier = String(window.id)
        let request = UNNotificationRequest(identifier: String(window.id), content: content, trigger: nil)
        center.add(request)
    }

    /// Done is a soft "Pop"; needs-you keeps a "Ping" so the two are easy to tell apart.
    func playSound(for state: ActivityState, volume: Double? = nil) {
        let level = volume ?? Settings.shared.soundVolume
        guard level > 0, let sound = NSSound(named: state == .done ? "Pop" : "Ping")?.copy() as? NSSound else { return }
        sound.volume = Float(level)
        sound.play()
    }

    func clear(for window: ManagedWindow) {
        center?.removeDeliveredNotifications(withIdentifiers: [String(window.id)])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["window"] as? Int
        Task { @MainActor in
            if let id { self.onOpen?(id) }
        }
        completionHandler()
    }

    /// Show banners even while the app is active (it usually is, as an accessory app).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
