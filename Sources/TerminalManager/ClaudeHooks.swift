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

    /// What kind of answer Claude is waiting for.
    enum Ask: String {
        case permission, question, plan
    }

    struct Status {
        let state: ActivityState
        /// When the latest event arrived.
        let time: Date
        /// What it's doing or asking ("Bash: npm test"), or its final message when done.
        let detail: String
        /// The prompt you gave it for the current task.
        let task: String
        let ask: Ask?
    }

    // MARK: Reading (in the app)

    private static func stateFile(forTTY tty: String) -> URL {
        stateDirectory.appendingPathComponent((tty as NSString).lastPathComponent + ".json")
    }

    /// Latest status Claude reported for the session in this tty, e.g. /dev/ttys003.
    static func status(forTTY tty: String) -> Status? {
        guard let data = try? Data(contentsOf: stateFile(forTTY: tty)),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let state = (json["state"] as? String).flatMap(ActivityState.init(rawValue:)),
              let seconds = json["time"] as? Double else { return nil }
        return Status(state: state, time: Date(timeIntervalSince1970: seconds),
                      detail: json["detail"] as? String ?? "", task: json["task"] as? String ?? "",
                      ask: (json["ask"] as? String).flatMap(Ask.init(rawValue:)))
    }

    /// You answered from the bar: show it as working right away, before Claude's next event.
    static func markAnswered(tty: String) {
        guard let status = status(forTTY: tty) else { return }
        let record: [String: Any] = ["state": ActivityState.working.rawValue, "time": Date().timeIntervalSince1970,
                                     "detail": status.detail, "task": status.task]
        if let data = try? JSONSerialization.data(withJSONObject: record) {
            try? data.write(to: stateFile(forTTY: tty), options: .atomic)
        }
    }

    // MARK: Hook invocation (a short-lived process started by Claude Code)

    /// Handles `TerminalManager --claude-hook <Event>`. Prints nothing: for some events Claude
    /// Code adds a hook's output to the conversation.
    static func runHook(event: String) -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
        guard let tty = controllingTTYName() else { exit(0) }
        let file = stateFile(forTTY: tty)
        let previous = status(forTTY: tty)

        var state: ActivityState
        var detail = ""
        var task = previous?.task ?? ""
        var ask: Ask?
        switch event {
        case "SessionStart":
            state = .idle
            task = ""
        case "UserPromptSubmit":
            state = .working
            task = clip(json["prompt"] as? String ?? "", 300)
        case "PostToolUse":
            state = .working
            detail = previous?.detail ?? ""
        case "PreToolUse":
            let tool = json["tool_name"] as? String ?? ""
            let toolInput = json["tool_input"] as? [String: Any] ?? [:]
            switch tool {
            case "AskUserQuestion":
                state = .needsInput
                ask = .question
                let questions = toolInput["questions"] as? [[String: Any]] ?? []
                detail = questions.compactMap { $0["question"] as? String }.joined(separator: "\n")
                if detail.isEmpty { detail = "Claude is asking you a question" }
            case "ExitPlanMode":
                state = .needsInput
                ask = .plan
                detail = "Plan ready for review:\n" + clip(toolInput["plan"] as? String ?? "", 600)
            default:
                state = .working
                detail = toolSummary(tool, toolInput)
            }
        case "Notification":
            let message = json["message"] as? String ?? ""
            let lower = message.lowercased()
            // "Claude is waiting for your input" is just the idle reminder after a finished turn.
            guard lower.contains("permission") || lower.contains("approv") || lower.contains("question") else { exit(0) }
            state = .needsInput
            if lower.contains("permission") {
                ask = .permission
                // PreToolUse just told us which tool and input it wants to run; show that.
                let pending = previous?.state == .working ? previous?.detail ?? "" : ""
                detail = pending.isEmpty ? message : pending
            } else {
                ask = previous?.ask ?? .question
                detail = previous?.detail.isEmpty == false ? previous!.detail : message
            }
        case "Stop":
            state = .done
            let last = json["last_assistant_message"] as? String
                ?? (json["transcript_path"] as? String).flatMap { lastAssistantText(transcriptPath: $0) } ?? ""
            detail = clip(last, 600)
        case "SessionEnd":
            try? FileManager.default.removeItem(at: file)
            exit(0)
        default:
            exit(0)
        }

        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        var record: [String: Any] = ["state": state.rawValue, "time": Date().timeIntervalSince1970,
                                     "detail": detail, "task": task]
        if let ask { record["ask"] = ask.rawValue }
        if let data = try? JSONSerialization.data(withJSONObject: record) {
            try? data.write(to: file, options: .atomic)
        }
        exit(0)
    }

    /// One line describing a tool call, e.g. "Bash: npm test" or "Edit: auth.ts".
    private static func toolSummary(_ tool: String, _ input: [String: Any]) -> String {
        if let command = input["command"] as? String { return "\(tool): " + clip(command, 200) }
        if let path = input["file_path"] as? String ?? input["notebook_path"] as? String {
            return "\(tool): " + (path as NSString).lastPathComponent
        }
        if let url = input["url"] as? String { return "\(tool): " + clip(url, 200) }
        if let pattern = input["pattern"] as? String { return "\(tool): " + clip(pattern, 120) }
        if let description = input["description"] as? String { return "\(tool): " + clip(description, 200) }
        return tool
    }

    /// The text of Claude's last reply, read from the end of the session transcript (JSON lines).
    private static func lastAssistantText(transcriptPath: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 256 * 1024
        try? handle.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  entry["type"] as? String == "assistant",
                  let message = entry["message"] as? [String: Any] else { continue }
            let blocks = message["content"] as? [[String: Any]] ?? []
            let texts = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { return joined }
        }
        return nil
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
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
