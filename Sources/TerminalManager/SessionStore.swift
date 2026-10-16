import AppKit
import Combine

/// Owns all terminals, polls their state and reacts to changes.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []

    /// Where the top bar is on screen, so windows can open just below it.
    var barFrame: (() -> NSRect?)?
    /// Called after every poll so the bar and menu bar icon can refresh.
    var onTick: (() -> Void)?

    private var timer: Timer?
    private var keyMonitor: Any?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // SwiftTerm does not let us override keyDown, so watch key presses app-wide and
        // credit them to the terminal that has focus.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                if let view = event.window?.firstResponder as? ManagedTerminalView,
                   let session = self?.sessions.first(where: { $0.terminalView === view }) {
                    session.userDidType()
                }
            }
            return event
        }
    }

    var attentionCount: Int { sessions.filter { $0.state.wantsAttention }.count }

    // MARK: Creating and closing

    @discardableResult
    func newSession(name: String? = nil, directory: String? = nil, show: Bool = true) -> TerminalSession {
        let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser.path
        let defaultName: String
        if directory != nil {
            defaultName = (dir as NSString).lastPathComponent
        } else {
            defaultName = "Terminal \(sessions.count + 1)"
        }
        let session = TerminalSession(name: name ?? defaultName, directory: dir)
        session.onStateChange = { [weak self] session, old, new in
            self?.stateChanged(session, from: old, to: new)
        }
        session.onExit = { [weak self] session in
            // Typing `exit` closes the terminal.
            self?.close(session)
        }
        session.onAutoHide = { [weak self] session in
            self?.autoHide(session)
        }
        sessions.append(session)
        save()
        if show { self.show(session) }
        return session
    }

    func newSessionInFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Terminal Here"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        newSession(directory: url.path)
    }

    func close(_ session: TerminalSession) {
        session.terminate()
        sessions.removeAll { $0 === session }
        Notifier.shared.clear(for: session)
        save()
    }

    func confirmAndClose(_ session: TerminalSession) {
        if session.state == .working || session.state == .needsInput {
            let alert = NSAlert()
            alert.messageText = "Close “\(session.name)”?"
            alert.informativeText = "\(session.processName) is still running in this terminal and will be stopped."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        close(session)
    }

    func rename(_ session: TerminalSession) {
        let alert = NSAlert()
        alert.messageText = "Rename terminal"
        alert.informativeText = "Give it a name that says what it is working on."
        let field = NSTextField(string: session.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            session.rename(name)
            save()
        }
    }

    // MARK: Showing and hiding

    func show(_ session: TerminalSession) {
        session.show(below: barFrame?())
        Notifier.shared.clear(for: session)
    }

    func toggle(_ session: TerminalSession) {
        if session.isFrontmost {
            session.hide()
        } else {
            show(session)
        }
    }

    func showNextNeedingAttention() {
        let ordered = sessions.filter { $0.state == .needsInput } + sessions.filter { $0.state == .done }
        if let session = ordered.first { show(session) }
    }

    func hideAll() {
        sessions.forEach { $0.hide() }
    }

    private func autoHide(_ session: TerminalSession) {
        session.hide()
        // Hand focus back to whatever you were doing, unless another terminal is still open.
        if !sessions.contains(where: { $0.window.isVisible }) {
            NSApp.deactivate()
        }
    }

    // MARK: Polling

    private func tick() {
        sessions.forEach { $0.tick() }
        onTick?()
    }

    private func stateChanged(_ session: TerminalSession, from old: ActivityState, to new: ActivityState) {
        objectWillChange.send()
        if session.isFrontmost { return }
        switch new {
        case .needsInput where old == .working:
            Notifier.shared.post(for: session, title: "\(session.name) needs you",
                                 body: session.programTitle.isEmpty ? "\(session.processName) is waiting for input." : session.programTitle)
        case .done:
            Notifier.shared.post(for: session, title: "\(session.name) finished",
                                 body: "The command finished in \((session.directory as NSString).abbreviatingWithTildeInPath).")
        case .working:
            Notifier.shared.clear(for: session)
        default:
            break
        }
    }

    // MARK: Persistence

    func save() {
        Settings.shared.savedSessions = sessions.map { SavedSession(name: $0.name, directory: $0.directory) }
    }

    func restore() {
        guard Settings.shared.restoreSessions else { return }
        for saved in Settings.shared.savedSessions {
            let dir = FileManager.default.fileExists(atPath: saved.directory) ? saved.directory : nil
            newSession(name: saved.name, directory: dir, show: false)
        }
    }

    func session(withID id: String) -> TerminalSession? {
        sessions.first { $0.id.uuidString == id }
    }
}
