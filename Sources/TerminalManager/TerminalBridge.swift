import AppKit

struct TabSnapshot {
    /// 1-based tab index inside its window, as AppleScript counts.
    let index: Int
    let tty: String
    let selected: Bool
    let customTitle: String
}

struct WindowSnapshot {
    let id: Int
    let miniaturized: Bool
    /// False while Terminal Manager keeps the window hidden in the bar.
    let visible: Bool
    let frontmost: Bool
    let title: String
    let tabs: [TabSnapshot]
}

enum BridgeFailure: Error {
    case notRunning
    /// You declined (or haven't yet allowed) Terminal Manager to control Terminal.
    case notAuthorized
    case other(String)
}

/// Reads and controls Terminal.app windows through AppleScript.
/// All scripts run one at a time on a private queue so polling never blocks the UI.
final class TerminalBridge: @unchecked Sendable {
    static let bundleID = "com.apple.Terminal"

    private let queue = DispatchQueue(label: "TerminalManager.TerminalBridge")
    /// Compiled once and reused; only touched on `queue`.
    private var snapshotScript: NSAppleScript?

    static var terminalApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    static var isTerminalFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    // Fields are separated by ASCII 31 (unit separator), records by ASCII 30.
    private static let snapshotSource = """
    if application id "com.apple.Terminal" is running then
        with timeout of 3 seconds
            tell application id "com.apple.Terminal"
                set us to character id 31
                set rs to character id 30
                set out to ""
                repeat with w in windows
                    try
                        set tabList to tabs of w
                        if (count of tabList) > 0 then
                            set isMini to false
                            set isVisible to true
                            set isFront to false
                            set wName to ""
                            try
                                set isMini to miniaturized of w
                            end try
                            try
                                set isFront to frontmost of w
                            end try
                            try
                                set isVisible to visible of w
                            end try
                            try
                                set wName to name of w
                            end try
                            set out to out & "W" & us & (id of w) & us & isMini & us & isFront & us & isVisible & us & wName & rs
                            set i to 0
                            repeat with t in tabList
                                set i to i + 1
                                set customTitle to ""
                                try
                                    set customTitle to custom title of t
                                end try
                                set isSelected to false
                                try
                                    set isSelected to selected of t
                                end try
                                set out to out & "T" & us & i & us & (tty of t) & us & isSelected & us & customTitle & rs
                            end repeat
                        end if
                    end try
                end repeat
                return out
            end tell
        end timeout
    else
        return "NOT_RUNNING"
    end if
    """

    func snapshot(_ completion: @escaping @MainActor (Result<[WindowSnapshot], BridgeFailure>) -> Void) {
        // Never send Apple Events to a Terminal that isn't running: that would launch it.
        guard Self.terminalApp != nil else {
            Task { @MainActor in completion(.failure(.notRunning)) }
            return
        }
        queue.async {
            if self.snapshotScript == nil {
                self.snapshotScript = NSAppleScript(source: Self.snapshotSource)
            }
            let result = self.execute(self.snapshotScript).flatMap { output -> Result<[WindowSnapshot], BridgeFailure> in
                output == "NOT_RUNNING" ? .failure(.notRunning) : .success(Self.parse(output))
            }
            Task { @MainActor in completion(result) }
        }
    }

    // MARK: Commands

    /// Unhides (or un-minimizes) the window, selects the tab and brings it to the front.
    func show(windowID: Int, tab: Int) {
        run("""
        tell application id "com.apple.Terminal"
            set w to window id \(windowID)
            set visible of w to true
            set miniaturized of w to false
            try
                set selected tab of w to tab \(tab) of w
            end try
            set index of w to 1
        end tell
        """, then: { Self.bringTerminalForward() })
    }

    /// Makes Terminal the active app, raising only its front window.
    ///
    /// AppleScript's `activate` raises every Terminal window, so this uses the activation call
    /// that brings forward just the key window. Since macOS 14 an app may only hand activation
    /// to another app while it's active itself, so we briefly activate (you just clicked us)
    /// and yield to Terminal.
    @MainActor
    static func bringTerminalForward() {
        guard let terminal = terminalApp else { return }
        NSApp.activate()
        NSApp.yieldActivation(to: terminal)
        if !terminal.activate(from: .current, options: []) {
            _ = terminal.activate(options: [])
        }
    }

    /// Hides the window without sending it to the Dock; its pill in the bar is the way back.
    func hide(windowID: Int) {
        run("""
        tell application id "com.apple.Terminal" to set visible of window id \(windowID) to false
        """)
    }

    /// Takes a window you minimized with the yellow button out of the Dock by making it
    /// invisible while it stays minimized. Never un-minimizes it, so nothing flashes; if macOS
    /// keeps it in the Dock anyway, it simply stays there.
    func moveFromDockToBar(windowID: Int) {
        run("""
        tell application id "com.apple.Terminal" to set visible of window id \(windowID) to false
        """)
    }

    /// When Terminal Manager quits, hidden windows go back to the Dock so they're never lost.
    /// Runs synchronously because the app is about to exit.
    func returnHiddenWindowsToDock() {
        guard Self.terminalApp != nil else { return }
        queue.sync {
            _ = self.execute(NSAppleScript(source: """
            with timeout of 3 seconds
                tell application id "com.apple.Terminal"
                    repeat with w in windows
                        try
                            if (count of tabs of w) > 0 and not (visible of w) then
                                set visible of w to true
                                set miniaturized of w to true
                            end if
                        end try
                    end repeat
                end tell
            end timeout
            """))
        }
    }

    /// Renames by setting the tab's custom title, so the name shows in Terminal too and sticks.
    func setTitle(_ title: String, windowID: Int, tab: Int) {
        run("""
        tell application id "com.apple.Terminal" to set custom title of tab \(tab) of window id \(windowID) to "\(Self.escape(title))"
        """)
    }

    /// Opens a new Terminal window, optionally in a folder.
    func newWindow(in directory: String? = nil) {
        // Shell-quote the path, then escape the whole command for the AppleScript string.
        let command = directory.map { Self.escape("cd \(Self.shellQuote($0)) && clear") } ?? ""
        let source = """
        tell application id "com.apple.Terminal"
            do script "\(command)"
        end tell
        """
        // Allowed even when Terminal isn't running: here launching it is the point.
        queue.async {
            _ = self.execute(NSAppleScript(source: source))
            Task { @MainActor in Self.bringTerminalForward() }
        }
    }

    /// Asks Terminal to close the window; Terminal itself warns if something is still running.
    func close(windowID: Int) {
        run("""
        tell application id "com.apple.Terminal"
            set w to window id \(windowID)
            set miniaturized of w to false
            set visible of w to true
            set index of w to 1
        end tell
        """, then: {
            // Bring it forward first, so Terminal's "Terminate running processes?" sheet is visible.
            Self.bringTerminalForward()
            self.run("""
            tell application id "com.apple.Terminal" to close window id \(windowID)
            """)
        })
    }

    // MARK: Plumbing

    private func run(_ source: String, then completion: (@MainActor () -> Void)? = nil) {
        guard Self.terminalApp != nil else { return }
        queue.async {
            _ = self.execute(NSAppleScript(source: source))
            if let completion { Task { @MainActor in completion() } }
        }
    }

    private func execute(_ script: NSAppleScript?) -> Result<String, BridgeFailure> {
        guard let script else { return .failure(.other("Could not create script")) }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            switch number {
            case -1743, -10004: return .failure(.notAuthorized)
            case -600, -609: return .failure(.notRunning)
            default: return .failure(.other(error[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(number)"))
            }
        }
        return .success(descriptor.stringValue ?? "")
    }

    /// Quotes a path for the shell, e.g. /Users/me/it's here -> '/Users/me/it'\''s here'.
    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func parse(_ output: String) -> [WindowSnapshot] {
        var windows: [WindowSnapshot] = []
        var current: (id: Int, mini: Bool, front: Bool, visible: Bool, title: String)?
        var tabs: [TabSnapshot] = []

        func flush() {
            if let current, !tabs.isEmpty {
                windows.append(WindowSnapshot(id: current.id, miniaturized: current.mini, visible: current.visible,
                                              frontmost: current.front,
                                              title: current.title, tabs: tabs))
            }
            current = nil
            tabs = []
        }

        for record in output.split(separator: "\u{1E}", omittingEmptySubsequences: true) {
            let fields = record.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "W" where fields.count >= 6:
                flush()
                guard let id = Int(fields[1]) else { continue }
                current = (id, fields[2] == "true", fields[3] == "true", fields[4] != "false",
                           fields[5...].joined(separator: " "))
            case "T" where fields.count >= 4 && current != nil:
                guard let index = Int(fields[1]) else { continue }
                let title = fields.count >= 5 ? fields[4...].joined(separator: " ") : ""
                tabs.append(TabSnapshot(index: index, tty: fields[2], selected: fields[3] == "true",
                                        customTitle: title == "missing value" ? "" : title))
            default:
                continue
            }
        }
        flush()
        return windows
    }
}
