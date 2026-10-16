import Foundation

/// User preferences, stored in UserDefaults and editable from the menu bar menu.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Keys.autoHide: true,
            Keys.notifications: true,
            Keys.sound: true,
            Keys.quietSeconds: 4.0,
            Keys.restoreSessions: true,
        ])
    }

    private enum Keys {
        static let autoHide = "autoHide"
        static let notifications = "notifications"
        static let sound = "sound"
        static let quietSeconds = "quietSeconds"
        static let restoreSessions = "restoreSessions"
        static let savedSessions = "savedSessions"
    }

    /// Hide a terminal window automatically once it goes back to working on its own.
    var autoHide: Bool {
        get { defaults.bool(forKey: Keys.autoHide) }
        set { defaults.set(newValue, forKey: Keys.autoHide) }
    }

    var notifications: Bool {
        get { defaults.bool(forKey: Keys.notifications) }
        set { defaults.set(newValue, forKey: Keys.notifications) }
    }

    var sound: Bool {
        get { defaults.bool(forKey: Keys.sound) }
        set { defaults.set(newValue, forKey: Keys.sound) }
    }

    /// How long a running program must be silent (and idle on CPU) before we assume it waits for you.
    var quietSeconds: Double {
        get { defaults.double(forKey: Keys.quietSeconds) }
        set { defaults.set(newValue, forKey: Keys.quietSeconds) }
    }

    /// Reopen the terminals (name + folder) that were open when the app quit.
    var restoreSessions: Bool {
        get { defaults.bool(forKey: Keys.restoreSessions) }
        set { defaults.set(newValue, forKey: Keys.restoreSessions) }
    }

    var savedSessions: [SavedSession] {
        get {
            guard let data = defaults.data(forKey: Keys.savedSessions) else { return [] }
            return (try? JSONDecoder().decode([SavedSession].self, from: data)) ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Keys.savedSessions) }
    }
}

struct SavedSession: Codable {
    var name: String
    var directory: String
}
