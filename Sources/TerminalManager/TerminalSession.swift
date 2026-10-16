import AppKit
import SwiftTerm
import SwiftUI

/// What a terminal is doing right now, as far as we can tell from the outside.
enum ActivityState: String {
    /// Shell prompt, nothing running.
    case idle
    /// A program is running and producing output or using CPU — on autopilot.
    case working
    /// A program is running but has gone quiet, or rang the bell: it probably waits for you.
    case needsInput
    /// A long-running command finished and you have not looked at it yet.
    case done
    /// The shell exited.
    case exited

    var color: SwiftUI.Color {
        switch self {
        case .idle: return .gray
        case .working: return .green
        case .needsInput: return .orange
        case .done: return .blue
        case .exited: return .red
        }
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .working: return "Working"
        case .needsInput: return "Needs you"
        case .done: return "Done"
        case .exited: return "Exited"
        }
    }

    /// States that should grab your attention.
    var wantsAttention: Bool { self == .needsInput || self == .done }
}

/// Thread-safe timestamp of the last output, written from SwiftTerm's IO thread.
final class OutputClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func mark() {
        lock.lock()
        last = Date()
        lock.unlock()
    }

    var lastOutput: Date {
        lock.lock()
        defer { lock.unlock() }
        return last
    }
}

/// SwiftTerm view that reports bells and pastes back to its session.
final class ManagedTerminalView: LocalProcessTerminalView {
    var onUserInput: (() -> Void)?
    var onBell: (() -> Void)?

    override func paste(_ sender: Any) {
        onUserInput?()
        super.paste(sender)
    }

    nonisolated override func bell(source: Terminal) {
        super.bell(source: source)
        Task { @MainActor [weak self] in self?.onBell?() }
    }
}

@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate, NSWindowDelegate {
    let id = UUID()

    @Published var name: String
    @Published private(set) var state: ActivityState = .idle
    /// Title set by the program via escape codes (e.g. Claude Code sets one per task).
    @Published private(set) var programTitle: String = ""
    /// Name of the foreground program, e.g. "claude", "npm", "zsh".
    @Published private(set) var processName: String = ""
    @Published private(set) var directory: String
    /// Never auto-hide this terminal's window.
    @Published var keepOpen = false

    /// Called when the state changes: (session, old state, new state).
    var onStateChange: ((TerminalSession, ActivityState, ActivityState) -> Void)?
    /// Called when the shell exits.
    var onExit: ((TerminalSession) -> Void)?
    /// Asked whether this session's window may be auto-hidden now.
    var onAutoHide: ((TerminalSession) -> Void)?

    let terminalView: ManagedTerminalView
    let window: NSWindow
    private let clock = OutputClock()
    private var oscObservation: TerminalOscObservation?

    private var lastInput = Date.distantPast
    private var bellPending = false
    private var commandStartedAt: Date?
    private var lastCPU: (group: pid_t, seconds: Double, at: Date)?
    private var cpuBusyUntil = Date.distantPast
    private var workingSince: Date?
    private var hasBeenPositioned = false
    /// Set when you open the window while the terminal waits for you; once it goes back
    /// to work on its own, the window hides again.
    private var autoHideArmed = false
    private var lastDirectoryCheck = Date.distantPast

    init(name: String, directory: String) {
        self.name = name
        self.directory = directory

        terminalView = ManagedTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        configureTerminal()
        configureWindow()
        startShell()
    }

    // MARK: Setup

    private func configureTerminal() {
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.nativeBackgroundColor = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.13, alpha: 1)
        terminalView.nativeForegroundColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        // Keep Option for typing characters like @ { [ on non-US keyboards.
        terminalView.optionAsMetaKey = false
        terminalView.processDelegate = self
        terminalView.onUserInput = { [weak self] in self?.userDidType() }
        terminalView.onBell = { [weak self] in self?.bellPending = true }

        let clock = self.clock
        terminalView.setProcessOutputHandler { clock.mark() }

        // OSC 9 / 99 / 777 are "desktop notification" escape codes; treat them like a bell.
        oscObservation = terminalView.observeOscEvents { [weak self] event in
            guard [9, 99, 777].contains(event.code) else { return }
            Task { @MainActor in self?.bellPending = true }
        }
    }

    private func configureWindow() {
        window.contentView = terminalView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 400, height: 200)
        window.tabbingMode = .disallowed
        updateWindowTitle()
    }

    private func startShell() {
        let shell = Self.userShell()
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "TerminalManager"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        let env = environment.map { "\($0.key)=\($0.value)" }

        let shellName = (shell as NSString).lastPathComponent
        terminalView.startProcess(
            executable: shell,
            args: [],
            environment: env,
            execName: "-\(shellName)", // leading dash = login shell, like Terminal.app
            currentDirectory: directory
        )
    }

    private static func userShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    // MARK: Status

    /// One line describing what the terminal is up to, shown under the name.
    var detail: String {
        switch state {
        case .needsInput: return programTitle.isEmpty ? "\(processName) · needs you" : programTitle
        case .working: return programTitle.isEmpty ? processName : programTitle
        case .done: return "Finished"
        case .idle: return (directory as NSString).abbreviatingWithTildeInPath
        case .exited: return "Exited"
        }
    }

    var isFrontmost: Bool { NSApp.isActive && window.isKeyWindow }

    func userDidType() {
        lastInput = Date()
        bellPending = false
    }

    /// Re-evaluates the state. Called a couple of times per second by the store.
    func tick() {
        guard state != .exited else { return }
        let now = Date()
        let process = terminalView.process!
        let shellPid = process.shellPid
        let foreground = ProcessInspector.foregroundGroup(ptyFD: process.childfd)
        let commandRunning = foreground > 0 && shellPid > 0 && foreground != shellPid

        if now.timeIntervalSince(lastDirectoryCheck) > 2 {
            lastDirectoryCheck = now
            let pid = commandRunning ? foreground : shellPid
            if let dir = ProcessInspector.workingDirectory(of: pid), dir != directory { directory = dir }
        }

        var newState: ActivityState
        if commandRunning {
            if commandStartedAt == nil {
                commandStartedAt = now
                lastCPU = nil
            }
            let name = ProcessInspector.name(of: foreground) ?? ""
            if name != processName { processName = name }

            // CPU usage of the whole foreground job (catches quiet compiles, installs...).
            let cpu = ProcessInspector.cpuSeconds(group: foreground)
            if let last = lastCPU, last.group == foreground {
                let elapsed = now.timeIntervalSince(last.at)
                if elapsed > 0, (cpu - last.seconds) / elapsed > 0.05 {
                    cpuBusyUntil = now.addingTimeInterval(1.5)
                }
            }
            lastCPU = (foreground, cpu, now)

            let quiet = now.timeIntervalSince(clock.lastOutput) >= Settings.shared.quietSeconds
            let typingRecently = now.timeIntervalSince(lastInput) < 1.5
            let busy = !quiet || now < cpuBusyUntil

            if bellPending {
                newState = .needsInput
            } else if busy && !(state == .needsInput && typingRecently) {
                // Output that is just the echo of your typing does not count as "back to work".
                newState = .working
            } else if busy {
                newState = state
            } else {
                newState = .needsInput
            }
        } else {
            let shellName = ProcessInspector.name(of: shellPid) ?? ""
            if shellName != processName { processName = shellName }
            let ranFor = commandStartedAt.map { now.timeIntervalSince($0) } ?? 0
            if commandStartedAt != nil, ranFor > 5, !isFrontmost {
                newState = .done
            } else if state == .done, !isFrontmost {
                newState = .done
            } else {
                newState = .idle
            }
            commandStartedAt = nil
            bellPending = false
        }

        if newState == .working {
            if workingSince == nil { workingSince = now }
        } else {
            workingSince = nil
        }

        if newState != state { setState(newState) }

        // Auto-hide: you answered, it is working again, and you stopped typing.
        if autoHideArmed, newState == .working, window.isVisible, !keepOpen, Settings.shared.autoHide,
           let since = workingSince, now.timeIntervalSince(since) > 2.0,
           now.timeIntervalSince(lastInput) > 2.0 {
            autoHideArmed = false
            onAutoHide?(self)
        }
    }

    private func setState(_ newState: ActivityState) {
        let old = state
        state = newState
        if newState == .needsInput || newState == .idle, window.isVisible { autoHideArmed = true }
        updateWindowTitle()
        onStateChange?(self, old, newState)
    }

    private func updateWindowTitle() {
        window.title = name
        window.subtitle = state.label + (programTitle.isEmpty ? "" : " — \(programTitle)")
    }

    func rename(_ newName: String) {
        name = newName
        updateWindowTitle()
    }

    // MARK: Window

    func show(below anchor: NSRect?) {
        if !hasBeenPositioned, let anchor, let screen = NSScreen.screens.first {
            let size = window.frame.size
            let x = anchor.midX - size.width / 2
            let y = anchor.minY - 8 - size.height
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: min(max(x, visible.minX), visible.maxX - size.width),
                y: max(y, visible.minY)
            ))
            hasBeenPositioned = true
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminalView)
        // Opening a terminal that waits for you arms auto-hide for when it resumes.
        autoHideArmed = state != .working
        markViewed()
    }

    func hide() {
        window.orderOut(nil)
    }

    private func markViewed() {
        if state == .done { setState(.idle) }
    }

    func terminate() {
        oscObservation?.cancel()
        terminalView.terminate()
        window.orderOut(nil)
    }

    // MARK: NSWindowDelegate

    /// The close button hides the window; the terminal keeps running.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        markViewed()
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        programTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updateWindowTitle()
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = URL(string: directory), url.isFileURL else { return }
        self.directory = url.path
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        setState(.exited)
        onExit?(self)
    }
}
