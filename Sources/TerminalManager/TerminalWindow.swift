import AppKit
import SwiftUI

/// What a terminal is doing right now, as far as we can tell from the outside.
enum ActivityState: String {
    /// Shell prompt, nothing running.
    case idle
    /// A program is running and producing output or using CPU — on autopilot.
    case working
    /// A program is running but has gone quiet: it probably waits for you.
    case needsInput
    /// A long-running command finished and you have not looked at it yet.
    case done

    var color: SwiftUI.Color {
        switch self {
        case .idle: return .gray
        case .working: return .green
        case .needsInput: return .orange
        case .done: return .blue
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
    private var cpuBusyUntil = Date.distantPast
    private var lastDirectoryCheck = Date.distantPast

    private static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "tcsh", "csh", "ksh", "dash", "nu", "-zsh", "-bash"]

    init(tty: String) {
        self.tty = tty
    }

    /// Re-evaluates the state. `viewed` means you are looking at this tab right now.
    func update(viewed: Bool) {
        let now = Date()
        let procs = ProcessInspector.processes(onTTY: tty)
        guard !procs.isEmpty else { return }
        let activity = ProcessInspector.ttyActivity(tty)
        if let activity { lastInput = activity.lastInput }

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
        if commandRunning {
            if commandStartedAt == nil {
                commandStartedAt = now
                lastCPU = nil
            }
            let job = procs.filter { $0.groupID == foreground }
            processName = job.first { $0.pid == foreground }?.name ?? job.first?.name ?? ""

            // CPU usage of the whole foreground job catches quiet compiles and installs.
            let cpu = job.reduce(0) { $0 + ProcessInspector.cpuSeconds(pid: $1.pid) }
            if let last = lastCPU, last.group == foreground {
                let elapsed = now.timeIntervalSince(last.at)
                if elapsed > 0, (cpu - last.seconds) / elapsed > 0.05 {
                    cpuBusyUntil = now.addingTimeInterval(2)
                }
            }
            lastCPU = (foreground, cpu, now)

            let lastOutput = activity?.lastOutput ?? .distantPast
            let quiet = now.timeIntervalSince(lastOutput) >= Settings.shared.quietSeconds
            let typingRecently = now.timeIntervalSince(lastInput) < 2
            let busy = !quiet || now < cpuBusyUntil

            if busy && !(state == .needsInput && typingRecently) {
                newState = .working
            } else if busy {
                // Output that is just the echo of your typing does not count as "back to work".
                newState = state
            } else {
                newState = .needsInput
            }
        } else {
            processName = shell?.name.trimmingCharacters(in: CharacterSet(charactersIn: "-")) ?? ""
            let ranFor = commandStartedAt.map { now.timeIntervalSince($0) } ?? 0
            if (commandStartedAt != nil && ranFor > 5 && !viewed) || (state == .done && !viewed) {
                newState = .done
            } else {
                newState = .idle
            }
            commandStartedAt = nil
        }

        if newState == .working {
            if workingSince == nil { workingSince = now }
        } else {
            workingSince = nil
        }
        state = newState
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
    @Published private(set) var isMiniaturized = false
    @Published private(set) var isFrontmostWindow = false
    @Published private(set) var tabCount = 1
    /// Never auto-minimize this window.
    @Published var keepOpen = false

    /// Called when the state changes: (window, old state, new state).
    var onStateChange: ((ManagedWindow, ActivityState, ActivityState) -> Void)?
    /// Called when the window should go back to the Dock on its own.
    var onAutoHide: ((ManagedWindow) -> Void)?

    private(set) var tabs: [TabSnapshot] = []
    private var monitors: [String: TabMonitor] = [:]
    /// Set when you look at the window while it waits for you; once it goes back
    /// to work on its own, it minimizes again.
    private var autoHideArmed = false
    private var wasViewed = false

    init(id: Int) {
        self.id = id
    }

    /// You are looking at it: Terminal is the active app and this is its front window.
    var isViewed: Bool { TerminalBridge.isTerminalFrontmost && isFrontmostWindow && !isMiniaturized }

    /// The tab that speaks for the window: most urgent, preferring the selected one.
    var urgentTab: TabSnapshot? {
        tabs.max { a, b in
            let ua = monitors[a.tty]?.state.urgency ?? 0, ub = monitors[b.tty]?.state.urgency ?? 0
            return ua != ub ? ua < ub : (!a.selected && b.selected)
        }
    }

    func apply(_ snapshot: WindowSnapshot) {
        tabs = snapshot.tabs
        if isMiniaturized != snapshot.miniaturized { isMiniaturized = snapshot.miniaturized }
        if isFrontmostWindow != snapshot.frontmost { isFrontmostWindow = snapshot.frontmost }
        if tabCount != snapshot.tabs.count { tabCount = snapshot.tabs.count }
        let ttys = Set(snapshot.tabs.map(\.tty))
        monitors = monitors.filter { ttys.contains($0.key) }
        for tty in ttys where monitors[tty] == nil { monitors[tty] = TabMonitor(tty: tty) }
    }

    /// Locally reflect a show/minimize right away instead of waiting for the next snapshot.
    func assume(miniaturized: Bool, frontmost: Bool) {
        isMiniaturized = miniaturized
        isFrontmostWindow = frontmost
        if !miniaturized { autoHideArmed = state != .working }
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
        let newName = [selected?.customTitle ?? "", folder, "Terminal"].first { !$0.isEmpty } ?? "Terminal"
        if newName != name { name = newName }
        if let dir = selectedMonitor?.directory, dir != directory { directory = dir }

        let program = monitor?.programLabel ?? ""
        var newDetail: String
        switch newState {
        case .needsInput: newDetail = program.isEmpty ? "Needs you" : "\(program) · needs you"
        case .working: newDetail = program.isEmpty ? "Working" : program
        case .done: newDetail = "Finished"
        case .idle: newDetail = (directory as NSString).abbreviatingWithTildeInPath
        }
        if tabs.count > 1 { newDetail = "\(tabs.count) tabs · " + newDetail }
        if newDetail != detail { detail = newDetail }

        // Looking at it while it waits for you (or sits idle) arms auto-minimize.
        if viewed, !wasViewed, newState != .working { autoHideArmed = true }
        if viewed, newState == .needsInput || newState == .idle { autoHideArmed = true }
        wasViewed = viewed

        if newState != state {
            let old = state
            state = newState
            onStateChange?(self, old, newState)
        }

        // Auto-minimize: you answered, it's working again, and you stopped typing.
        let now = Date()
        if autoHideArmed, newState == .working, viewed, !keepOpen, Settings.shared.autoHide,
           let since = monitor?.workingSince, now.timeIntervalSince(since) > 2.5,
           let lastInput = monitor?.lastInput, now.timeIntervalSince(lastInput) > 2.5 {
            autoHideArmed = false
            onAutoHide?(self)
        }
    }
}
