import Foundation

/// User preferences, stored in UserDefaults and editable from the menu bar menu.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Keys.autoHide: false, // off: hiding a window you're still thinking in is jarring
            Keys.notifications: true,
            Keys.sound: true,
            Keys.quietSeconds: 4.0,
            // Off: pulling a window out of the Dock means un-minimizing it first, which flashes.
            Keys.keepMinimizedInBar: false,
        ])
    }

    private enum Keys {
        // New key so earlier installs also start with auto-hide off.
        static let autoHide = "autoHideEnabled"
        static let notifications = "notifications"
        static let sound = "sound"
        static let quietSeconds = "quietSeconds"
        static let didSetUpLoginItem = "didSetUpLoginItem"
        // New key so earlier installs also start with it off.
        static let keepMinimizedInBar = "moveMinimizedToBar"
    }

    /// Hide a Terminal window automatically once it goes back to working on its own. Opt-in.
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

    /// Windows you minimize with the yellow button go to the bar instead of the Dock.
    var keepMinimizedInBar: Bool {
        get { defaults.bool(forKey: Keys.keepMinimizedInBar) }
        set { defaults.set(newValue, forKey: Keys.keepMinimizedInBar) }
    }

    /// Whether we already turned on "Open at Login" once (so we never override your choice).
    var didSetUpLoginItem: Bool {
        get { defaults.bool(forKey: Keys.didSetUpLoginItem) }
        set { defaults.set(newValue, forKey: Keys.didSetUpLoginItem) }
    }
}
