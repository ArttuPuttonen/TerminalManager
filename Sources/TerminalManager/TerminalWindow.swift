import AppKit
import SwiftUI

/// What a terminal is doing right now, as far as we can tell from the outside.
enum ActivityState: String {
    /// Shell prompt, nothing running.
    case idle
    /// A program is running and producing output or using CPU — on autopilot.
    case working
    /// It's asking you something (permission, a question). Reported by Claude Code hooks.
    case needsInput
    /// Finished a stretch of work and you haven't looked at it yet.
    case done

    var color: SwiftUI.Color {
        switch self {
        case .idle: return .gray
        case .working: return .blue
        case .needsInput: return .orange
        case .done: return .green
        }
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .working: return "Working"
        case .needsInput: return "Needs you"
        case .done: return "Done"
        }
    }

    /// States that should grab your attention.
    var wantsAttention: Bool { self == .needsInput || self == .done }

    /// Which tab speaks for a window: the most urgent one.
    var urgency: Int {
        switch self {
        case .needsInput: return 3
        case .done: return 2
        case .working: return 1
        case .idle: return 0
        }
    }
}

/// Watches one Terminal tab through its tty device.
@MainActor
final class TabMonitor {
    let tty: String
    private(set) var state: ActivityState = .idle
    private(set) var processName = ""
    private(set) var directory = ""
    private(set) var lastInput = Date.distantPast
    private(set) var workingSince: Date?

    private var commandStartedAt: Date?
    private var lastCPU: (group: pid_t, seconds: Double, at: Date)?
    private var lastCPUHot = Date.distantPast
    private var lastDirectoryCheck = Date.distantPast
    /// Start of the current unbroken stretch of activity (output or CPU), if any.
    private var activeSince: Date?
    /// When the latest stretch of real work began, to judge whether going quiet deserves a chime.
    private var workStartedAt: Date?
    private var lastAlertAt = Date.distantPast
    /// Set on the tick where the tab stops working after real work; read once by the window.
    private(set) var alertPending = false
    private(set) var diagnostics = ""
    /// What Claude Code reported for the session running in this tab, when hooks are connected.
    private(set) var hook: ClaudeHooks.Status?
    /// When the current state began (for "working 3m", "waiting 5m").
    private(set) var stateSince = Date()
    /// When it entered the current state, or finished, for display.
    var displaySince: Date { state == .done ? (doneAt ?? stateSince) : stateSince }
    /// When the current "done" happened; identifies it so seeing it can retire it.
    private var doneAt: Date?
    /// The latest "done" you have looked at, and the latest one you looked at and then left.
    private var seenDoneAt: Date?
    private var acknowledgedDoneAt: Date?

    /// A job counts as busy on CPU above this share of one core.
    private static let cpuThreshold = 0.15
    /// Going from "needs you" back to "working" takes this much unbroken activity,
    /// so an occasional redraw or timer tick from a waiting program doesn't count.
    private static let resumeAfter: TimeInterval = 3
    /// Only chime if it worked at least this long before going quiet.
    private static let minimumWorkForAlert: TimeInterval = 5

    private static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "tcsh", "csh", "ksh", "dash", "nu", "-zsh", "-bash"]

    init(tty: String) {
        self.tty = tty
    }

    /// Re-evaluates the state. `viewed` means you are looking at this tab right now.
    func update(viewed: Bool) {
        let now = Date()
        alertPending = false
        let procs = ProcessInspector.processes(onTTY: tty)
        guard !procs.isEmpty else { return }
        let activity = ProcessInspector.ttyActivity(tty)
        if let activity { lastInput = activity.lastInput }
        let lastOutput = activity?.lastOutput ?? .distantPast

        // The shell is the first process Terminal started in this tab (usually a child of `login`).
        let pids = Set(procs.map(\.pid))
        let names = Dictionary(procs.map { ($0.pid, $0.name) }, uniquingKeysWith: { first, _ in first })
        let shell = procs
            .filter { $0.name != "login" && (names[$0.parentPid] == "login" || !pids.contains($0.parentPid)) }
            .min { $0.pid < $1.pid }
        let foreground = procs.first { $0.terminalGroupID > 0 }?.terminalGroupID ?? -1
        let commandRunning = shell != nil && foreground > 0 && foreground != shell!.groupID

        if now.timeIntervalSince(lastDirectoryCheck) > 2, let shell {
            lastDirectoryCheck = now
            if let dir = ProcessInspector.workingDirectory(of: commandRunning ? foreground : shell.pid) { directory = dir }
        }

        var newState: ActivityState
        var cpuRate = 0.0
        var source = "guess"
        if commandRunning {
            if commandStartedAt == nil {
                commandStartedAt = now
                lastCPU = nil
                activeSince = nil
            }
            let job = procs.filter { $0.groupID == foreground }
            let leader = job.first { $0.pid == foreground } ?? job.first
            processName = leader.map { ProcessInspector.displayName(pid: $0.pid, processName: $0.name) } ?? ""

            // CPU usage of the whole foreground job catches quiet compiles and installs.
            let cpu = job.reduce(0) { $0 + ProcessInspector.cpuSeconds(pid: $1.pid) }
            if let last = lastCPU, last.group == foreground {
                let elapsed = now.timeIntervalSince(last.at)
                if elapsed > 0 { cpuRate = (cpu - last.seconds) / elapsed }
                if cpuRate > Self.cpuThreshold { lastCPUHot = now }
            }
            lastCPU = (foreground, cpu, now)

            // tty timestamps have ~1 s precision, so "recent" means within 1.5 s.
            let lastActivity = max(lastOutput, lastCPUHot)
            let activeNow = now.timeIntervalSince(lastActivity) < 1.5
            if activeNow {
                if activeSince == nil { activeSince = now }
            } else {
                activeSince = nil
            }
            let activeFor = activeSince.map { now.timeIntervalSince($0) } ?? 0
            let quiet = now.timeIntervalSince(lastActivity) >= Settings.shared.quietSeconds
            let typingRecently = now.timeIntervalSince(lastInput) < 2

            self.hook = nil
            if let hook = ClaudeHooks.status(forTTY: tty),
               hook.time >= (commandStartedAt ?? now).addingTimeInterval(-2) {
                // Exact: Claude Code told us what it's doing (see ClaudeHooks).
                source = "claude-hooks"
                self.hook = hook
                newState = hook.state == .done ? doneState(finishedAt: hook.time, viewed: viewed) : hook.state
            } else {
                // Guess from output and CPU. Without hooks we can't tell "asking you something"
                // from "finished", so going quiet after real work counts as done, never orange.
                let justStarted = now.timeIntervalSince(commandStartedAt ?? now) < 3
                switch state {
                case .working:
                    if quiet {
                        let workedFor = workStartedAt.map { now.timeIntervalSince($0) } ?? 0
                        newState = workedFor >= Self.minimumWorkForAlert ? doneState(finishedAt: now, viewed: viewed) : .idle
                    } else {
                        newState = .working
                    }
                case .idle, .done, .needsInput:
                    // Needs sustained activity (a waiting program's occasional redraw isn't work),
                    // and output while you type is just your own echo.
                    if activeNow && (justStarted || (activeFor >= Self.resumeAfter && !typingRecently)) {
                        newState = .working
                    } else if state == .done, let doneAt {
                        newState = doneState(finishedAt: doneAt, viewed: viewed)
                    } else {
                        newState = state == .needsInput ? .idle : state
                    }
                }
            }
        } else {
            processName = shell?.name.trimmingCharacters(in: CharacterSet(charactersIn: "-")) ?? ""
            hook = nil
            let ranFor = commandStartedAt.map { now.timeIntervalSince($0) } ?? 0
            if commandStartedAt != nil && ranFor > 5 {
                newState = doneState(finishedAt: now, viewed: viewed)
            } else if state == .done, let doneAt {
                newState = doneState(finishedAt: doneAt, viewed: viewed)
            } else {
                newState = .idle
            }
            commandStartedAt = nil
            activeSince = nil
        }

        if newState == .working {
            if workingSince == nil { workingSince = now }
            if workStartedAt == nil { workStartedAt = now }
        } else {
            workingSince = nil
        }

        // Chime once each time it starts asking you something.
        if newState == .needsInput, state != .needsInput, now.timeIntervalSince(lastAlertAt) > 2 {
            alertPending = true
            lastAlertAt = now
        }
        if newState != .working { workStartedAt = nil }
        if newState != state { stateSince = now }
        state = newState

        diagnostics = String(
            format: "%@ via=%@ state=%@ cmd=%@ fg=%d shell=%@ out=%.1fs ago in=%.1fs ago cpu=%.0f%%  procs=%@",
            tty, source, state.rawValue, commandRunning ? processName : "-", foreground,
            shell.map { "\($0.name)(\($0.pid)/pg\($0.groupID))" } ?? "none",
            now.timeIntervalSince(lastOutput), now.timeIntervalSince(lastInput), cpuRate * 100,
            procs.map { "\($0.name):\($0.pid)/pg\($0.groupID)" }.joined(separator: ",")
        )
    }

    /// Something finished at `finishedAt`. It stays green ("done") until you've looked at it
    /// and then moved on (hid it, or switched to another window or app); then it's gray.
    /// While you're looking at it, it stays green.
    private func doneState(finishedAt: Date, viewed: Bool) -> ActivityState {
        doneAt = finishedAt
        if let acknowledged = acknowledgedDoneAt, acknowledged >= finishedAt { return .idle }
        if viewed {
            seenDoneAt = finishedAt
            return .done
        }
        if let seen = seenDoneAt, seen >= finishedAt {
            acknowledgedDoneAt = finishedAt
            return .idle
        }
        return .done
    }

    /// Short description of the program, for the pill's second line.
    var programLabel: String {
        Self.shells.contains(processName) ? "" : processName
    }
}

/// One Terminal.app window, shown as a pill in the bar.
@MainActor
final class ManagedWindow: ObservableObject, Identifiable {
    let id: Int

    @Published private(set) var name = ""
    @Published private(set) var state: ActivityState = .idle
    @Published private(set) var detail = ""
    @Published private(set) var directory = ""
    /// Hidden in the bar (or minimized to the Dock): not on screen.
    @Published private(set) var isHidden = false
    @Published private(set) var isFrontmostWindow = false
    @Published private(set) var tabCount = 1
    /// What the hover card shows for this window.
    struct Preview: Equatable {
        var state: ActivityState
        var headline: String
        var message: String
        var task: String
        /// A permission request we can answer with "Allow" from the card.
        var canAllow: Bool
    }
    @Published private(set) var preview = Preview(state: .idle, headline: "", message: "", task: "", canAllow: false)

    /// When it finished (done/idle) or entered its current state, for choosing what to hide.
    private(set) var restingSince = Date()

    /// Never auto-hide this window.
    @Published var keepOpen = false

    /// Called when the state changes: (window, old state, new state).
    var onStateChange: ((ManagedWindow, ActivityState, ActivityState) -> Void)?
    /// Called when a tab finished real work and now waits for you (at most once per wait).
    var onNeedsYou: ((ManagedWindow) -> Void)?
    /// Called when the window should go back to the Dock on its own.
    var onAutoHide: ((ManagedWindow) -> Void)?

    private(set) var tabs: [TabSnapshot] = []
    private var monitors: [String: TabMonitor] = [:]
    /// Set when you look at the window while it waits for you; once it goes back
    /// to work on its own, it hides again.
    private var autoHideArmed = false
    private var wasViewed = false

    init(id: Int) {
        self.id = id
    }

    /// You are looking at it: Terminal is the active app and this is its front window.
    var isViewed: Bool { TerminalBridge.isTerminalFrontmost && isFrontmostWindow && !isHidden }

    /// The tab that speaks for the window: most urgent, preferring the selected one.
    var urgentTab: TabSnapshot? {
        tabs.max { a, b in
            let ua = monitors[a.tty]?.state.urgency ?? 0, ub = monitors[b.tty]?.state.urgency ?? 0
            return ua != ub ? ua < ub : (!a.selected && b.selected)
        }
    }

    /// "<1m", "3m", "1h 5m".
    static func elapsed(since date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    /// The tab whose permission request "Allow" answers, re-checked right before sending.
    var permissionTab: TabSnapshot? {
        tabs.first { tab in
            guard let status = ClaudeHooks.status(forTTY: tab.tty) else { return false }
            return status.state == .needsInput && status.ask == .permission
        }
    }

    /// Programs like Claude Code put a spinner or status glyph in front of the tab title
    /// ("✳ Terminal manager"); the dot already shows status, so drop it.
    static func cleanTitle(_ title: String) -> String {
        let trimmed = title.drop { !$0.isLetter && !$0.isNumber }
        return String(trimmed).trimmingCharacters(in: .whitespaces)
    }

    /// What each tab looks like to the detector, for "Copy Diagnostics".
    var diagnostics: String {
        "Window \(id) \"\(name)\" state=\(state.rawValue) viewed=\(isViewed) hidden=\(isHidden)\n"
            + tabs.map { "  tab \($0.index)\($0.selected ? "*" : ""): " + (monitors[$0.tty]?.diagnostics ?? $0.tty) }
                .joined(separator: "\n")
    }

    func apply(_ snapshot: WindowSnapshot) {
        tabs = snapshot.tabs
        let hidden = snapshot.miniaturized || !snapshot.visible
        if isHidden != hidden { isHidden = hidden }
        if isFrontmostWindow != snapshot.frontmost { isFrontmostWindow = snapshot.frontmost }
        if tabCount != snapshot.tabs.count { tabCount = snapshot.tabs.count }
        let ttys = Set(snapshot.tabs.map(\.tty))
        monitors = monitors.filter { ttys.contains($0.key) }
        for tty in ttys where monitors[tty] == nil { monitors[tty] = TabMonitor(tty: tty) }
    }

    /// Locally reflect a show/hide right away instead of waiting for the next snapshot.
    func assume(hidden: Bool, frontmost: Bool) {
        isHidden = hidden
        isFrontmostWindow = frontmost
        if !hidden { autoHideArmed = state != .working }
    }

    func tick() {
        let viewed = isViewed
        for tab in tabs {
            monitors[tab.tty]?.update(viewed: viewed && tab.selected)
        }
        let urgent = urgentTab
        let monitor = urgent.flatMap { monitors[$0.tty] }
        let newState = monitor?.state ?? .idle

        // Name: your custom title, else the folder the tab is in.
        let selected = tabs.first(where: \.selected) ?? tabs.first
        let selectedMonitor = selected.flatMap { monitors[$0.tty] }
        let folder = selectedMonitor.map { ($0.directory as NSString).lastPathComponent } ?? ""
        let title = Self.cleanTitle(selected?.customTitle ?? "")
        let newName = [title, folder, "Terminal"].first { !$0.isEmpty } ?? "Terminal"
        if newName != name { name = newName }
        if let dir = selectedMonitor?.directory, dir != directory { directory = dir }

        let program = monitor?.programLabel ?? ""
        let hook = monitor?.hook
        let elapsed = monitor.map { Self.elapsed(since: $0.displaySince) } ?? ""
        var newDetail: String
        switch newState {
        case .needsInput:
            switch hook?.ask {
            case .permission: newDetail = "Permission · \(elapsed)"
            case .question: newDetail = "Question · \(elapsed)"
            case .plan: newDetail = "Plan to review · \(elapsed)"
            case nil: newDetail = "Needs you · \(elapsed)"
            }
        case .working: newDetail = (program.isEmpty ? "Working" : program) + " · \(elapsed)"
        case .done: newDetail = "Done \(elapsed) ago"
        case .idle:
            let path = (directory as NSString).abbreviatingWithTildeInPath
            newDetail = path.isEmpty || path == "~" ? "Idle" : path
        }
        if tabs.count > 1 { newDetail = "\(tabs.count) tabs · " + newDetail }
        if newDetail != detail { detail = newDetail }

        let headline: String
        switch newState {
        case .needsInput:
            switch hook?.ask {
            case .permission: headline = "Wants permission · waiting \(elapsed)"
            case .question: headline = "Asking you · waiting \(elapsed)"
            case .plan: headline = "Plan ready · waiting \(elapsed)"
            case nil: headline = "Needs you · \(elapsed)"
            }
        case .working: headline = "Working · \(elapsed)"
        case .done: headline = "Done \(elapsed) ago"
        case .idle: headline = "Idle"
        }
        let message: String
        switch newState {
        case .working, .needsInput, .done: message = hook?.detail ?? ""
        case .idle: message = (directory as NSString).abbreviatingWithTildeInPath
        }
        let newPreview = Preview(state: newState, headline: headline, message: message,
                                 task: hook?.task ?? "",
                                 canAllow: newState == .needsInput && hook?.ask == .permission)
        if newPreview != preview { preview = newPreview }
        if let since = monitor?.displaySince { restingSince = since }

        // Looking at it while it waits for you (or sits idle) arms auto-hide.
        if viewed, !wasViewed, newState != .working { autoHideArmed = true }
        if viewed, newState == .needsInput || newState == .idle { autoHideArmed = true }
        wasViewed = viewed

        if newState != state {
            let old = state
            state = newState
            onStateChange?(self, old, newState)
        }
        if tabs.contains(where: { monitors[$0.tty]?.alertPending == true }) {
            onNeedsYou?(self)
        }

        // Auto-hide: you answered, it's working again, and you stopped typing.
        let now = Date()
        if autoHideArmed, newState == .working, viewed, !keepOpen, Settings.shared.autoHide,
           let since = monitor?.workingSince, now.timeIntervalSince(since) > 2.5,
           let lastInput = monitor?.lastInput, now.timeIntervalSince(lastInput) > 2.5 {
            autoHideArmed = false
            onAutoHide?(self)
        }
    }
}
