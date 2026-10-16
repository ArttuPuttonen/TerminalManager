import AppKit
import UserNotifications

/// Posts macOS notifications ("Terminal 2 needs you") and plays a sound.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Called when you click a notification, with the session id.
    var onOpen: ((String) -> Void)?

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

    func post(for session: TerminalSession, title: String, body: String) {
        if Settings.shared.sound {
            NSSound(named: session.state == .done ? "Glass" : "Ping")?.play()
        }
        guard Settings.shared.notifications, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["session": session.id.uuidString]
        content.threadIdentifier = session.id.uuidString
        let request = UNNotificationRequest(identifier: session.id.uuidString, content: content, trigger: nil)
        center.add(request)
    }

    func clear(for session: TerminalSession) {
        center?.removeDeliveredNotifications(withIdentifiers: [session.id.uuidString])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["session"] as? String
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
