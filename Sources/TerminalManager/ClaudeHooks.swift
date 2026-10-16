import Darwin
import Foundation

/// Exact status for Claude Code sessions, reported by Claude Code itself through hooks.
///
/// When connected, `~/.claude/settings.json` runs this app's binary with `--claude-hook <Event>`
/// at key moments. That invocation writes the session's status to a small file named after the
/// terminal (tty) Claude runs in, and exits. The running app reads those files when it polls.
enum ClaudeHooks {
    static let hookFlag = "--claude-hook"

    /// Hook events we listen to. All are long-standing Claude Code hook events.
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"]
    /// Tool events need a matcher; "*" matches every tool.
    private static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse"]
    /// Tools that stop and ask you something.
    private static let askingTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    static var stateDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TerminalManager/claude", isDirectory: true)
    }

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    struct Status {
        let state: ActivityState
        let time: Date
        let detail: String
    }

    // MARK: Reading (in the app)

    /// Latest status Claude reported for the session in this tty, e.g. /dev/ttys003.
    static func status(forTTY tty: String) -> Status? {
        let url = stateDirectory.appendingPathComponent((tty as NSString).lastPathComponent)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let fields = text.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 2, let state = ActivityState(rawValue: fields[0]), let seconds = Double(fields[1]) else {
            return nil
        }
        return Status(state: state, time: Date(timeIntervalSince1970: seconds),
                      detail: fields.count > 2 ? fields[2].trimmingCharacters(in: .whitespacesAndNewlines) : "")
    }

    // MARK: Hook invocation (a short-lived process started by Claude Code)

    /// Handles `TerminalManager --claude-hook <Event>`. Prints nothing: for some events Claude
    /// Code adds a hook's output to the conversation.
    static func runHook(event: String) -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
        guard let tty = controllingTTYName() else { exit(0) }
        let file = stateDirectory.appendingPathComponent(tty)

        let state: ActivityState
        var detail = ""
        switch event {
        case "SessionStart":
            state = .idle
        case "UserPromptSubmit", "PostToolUse":
            state = .working
        case "PreToolUse":
            let tool = json["tool_name"] as? String ?? ""
            if askingTools.contains(tool) {
                state = .needsInput
                detail = tool == "ExitPlanMode" ? "Plan ready for review" : "Asking you a question"
            } else {
                state = .working
            }
        case "Notification":
            let message = json["message"] as? String ?? ""
            let lower = message.lowercased()
            // "Claude is waiting for your input" is just the idle reminder after a finished turn.
            guard lower.contains("permission") || lower.contains("approv") || lower.contains("question") else { exit(0) }
            state = .needsInput
            detail = message
        case "Stop":
            state = .done
        case "SessionEnd":
            try? FileManager.default.removeItem(at: file)
            exit(0)
        default:
            exit(0)
        }

        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let line = "\(state.rawValue)\t\(Date().timeIntervalSince1970)\t\(detail.replacingOccurrences(of: "\n", with: " "))\n"
        try? line.write(to: file, atomically: true, encoding: .utf8)
        exit(0)
    }

    /// The terminal this hook belongs to: the first process up the parent chain that has
    /// a controlling terminal (Claude Code itself, or its shell). Returns e.g. "ttys003".
    private static func controllingTTYName() -> String? {
        var pid = getpid()
        for _ in 0..<8 {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
            let dev = info.kp_eproc.e_tdev
            if dev != -1, let name = devname(dev, mode_t(S_IFCHR)) {
                let tty = String(cString: name)
                if tty.hasPrefix("tty") { return tty }
            }
            let parent = info.kp_eproc.e_ppid
            guard parent > 1 else { return nil }
            pid = parent
        }
        return nil
    }

    // MARK: Connecting (editing ~/.claude/settings.json)

    private static func hookCommand(_ event: String) -> String? {
        guard let binary = Bundle.main.executablePath else { return nil }
        return "\"\(binary)\" \(hookFlag) \(event)"
    }

    private static func isOurs(_ entry: Any) -> Bool {
        guard let group = entry as? [String: Any], let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String)?.contains(hookFlag) == true }
    }

    private static func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "TerminalManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "~/.claude/settings.json isn't a JSON object."])
        }
        return object
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        let directory = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let backup = directory.appendingPathComponent("settings.json.terminalmanager-backup")
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    /// Whether our hooks are in Claude Code's settings, pointing at this copy of the app.
    static var isConnected: Bool {
        guard let settings = try? readSettings(), let hooks = settings["hooks"] as? [String: Any],
              let command = hookCommand("Stop") else { return false }
        let stop = hooks["Stop"] as? [Any] ?? []
        return stop.contains { entry in
            ((entry as? [String: Any])?["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String) == command } == true
        }
    }

    /// Adds our hooks, keeping all of your existing settings and hooks. Backs up the file first.
    static func connect() throws {
        var settings = try readSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            guard let command = hookCommand(event) else { continue }
            var entries = (hooks[event] as? [Any] ?? []).filter { !isOurs($0) }
            var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
            if toolEvents.contains(event) { group["matcher"] = "*" }
            entries.append(group)
            hooks[event] = entries
        }
        settings["hooks"] = hooks
        try writeSettings(settings)
    }

    /// Removes only our hooks.
    static func disconnect() throws {
        var settings = try readSettings()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard let entries = value as? [Any] else { continue }
            let kept = entries.filter { !isOurs($0) }
            if kept.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = kept
            }
        }
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        try writeSettings(settings)
    }

    /// Keep the hook path current if the app moved (e.g. rebuilt into /Applications).
    static func refreshIfConnectedElsewhere() {
        guard let settings = try? readSettings(), let hooks = settings["hooks"] as? [String: Any] else { return }
        let hasOurs = hooks.values.contains { ($0 as? [Any])?.contains(where: isOurs) == true }
        if hasOurs && !isConnected { try? connect() }
    }
}
