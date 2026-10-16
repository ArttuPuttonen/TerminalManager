import AppKit
import Combine

/// Tracks every Terminal.app window, polls their state and reacts to changes.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var windows: [ManagedWindow] = []
    /// macOS hasn't allowed us to read Terminal's windows (Privacy & Security → Automation).
    @Published private(set) var accessDenied = false

    /// Called after every poll so the bar and menu bar icon can refresh.
    var onTick: (() -> Void)?

    private let bridge = TerminalBridge()
    private var timer: Timer?
    private var snapshotInFlight = false
    private var lastSnapshot = Date.distantPast
    /// How often we tried to take each minimized window out of the Dock.
    private var dockAttempts: [Int: Int] = [:]

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == TerminalBridge.bundleID else { return }
                MainActor.assumeIsolated { self?.refreshSoon() }
            }
        }
        refreshSnapshot()
    }

    var attentionCount: Int { windows.filter { $0.state.wantsAttention }.count }

    // MARK: Polling

    private func tick() {
        // Window list from Terminal every ~1.5 s (AppleScript); tty state every 0.5 s (cheap, local).
        if Date().timeIntervalSince(lastSnapshot) > 1.5 { refreshSnapshot() }
        windows.forEach { $0.tick() }
        onTick?()
    }

    private func refreshSoon() {
        lastSnapshot = .distantPast
    }

    private func refreshSnapshot() {
        guard !snapshotInFlight else { return }
        snapshotInFlight = true
        lastSnapshot = Date()
        bridge.snapshot { [weak self] result in
            guard let self else { return }
            self.snapshotInFlight = false
            switch result {
            case .success(let snapshots):
                if self.accessDenied { self.accessDenied = false }
                self.apply(snapshots)
            case .failure(.notRunning):
                self.apply([])
            case .failure(.notAuthorized):
                if !self.accessDenied { self.accessDenied = true }
                self.apply([])
            case .failure(.other):
                break // transient (e.g. Terminal busy); keep what we have
            }
        }
    }

    private func apply(_ snapshots: [WindowSnapshot]) {
        let byID = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Keep existing pills where they are; new windows join at the end.
        var updated = windows.filter { byID[$0.id] != nil }
        for snapshot in snapshots where !updated.contains(where: { $0.id == snapshot.id }) {
            let window = ManagedWindow(id: snapshot.id)
            window.onStateChange = { [weak self] window, old, new in self?.stateChanged(window, from: old, to: new) }
            window.onNeedsYou = { [weak self] window in self?.needsYou(window) }
            window.onAutoHide = { [weak self] window in self?.hide(window) }
            updated.append(window)
        }
        for window in updated {
            guard let snapshot = byID[window.id] else { continue }
            window.apply(snapshot)
            // Minimized with the yellow button (or ⌘M) and still in the Dock? Take it out.
            // At most twice per minimize, in case macOS won't let it go.
            if snapshot.miniaturized && snapshot.visible {
                let attempts = dockAttempts[window.id, default: 0]
                if Settings.shared.keepMinimizedInBar, attempts < 2 {
                    dockAttempts[window.id] = attempts + 1
                    bridge.moveFromDockToBar(windowID: window.id)
                }
            } else if !snapshot.miniaturized {
                dockAttempts[window.id] = nil
            }
        }
        let removed = windows.filter { byID[$0.id] == nil }
        removed.forEach { Notifier.shared.clear(for: $0) }
        if updated.map(\.id) != windows.map(\.id) {
            windows = updated
            updated.forEach { $0.tick() }
        }
    }

    // MARK: Actions

    func show(_ window: ManagedWindow) {
        guard let tab = window.urgentTab ?? window.tabs.first else { return }
        bridge.show(windowID: window.id, tab: tab.index)
        window.assume(hidden: false, frontmost: true)
        Notifier.shared.clear(for: window)
        refreshSoon()
    }

    func hide(_ window: ManagedWindow) {
        bridge.hide(windowID: window.id)
        window.assume(hidden: true, frontmost: false)
        refreshSoon()
    }

    func toggle(_ window: ManagedWindow) {
        if window.isViewed {
            hide(window)
        } else {
            show(window)
        }
    }

    func showNextNeedingAttention() {
        let ordered = windows.filter { $0.state == .needsInput } + windows.filter { $0.state == .done }
        if let window = ordered.first { show(window) }
    }

    func hideAll() {
        windows.filter { !$0.isHidden }.forEach { hide($0) }
    }

    func returnHiddenWindowsToDock() {
        bridge.returnHiddenWindowsToDock()
    }

    func rename(_ window: ManagedWindow) {
        guard let tab = window.tabs.first(where: \.selected) ?? window.tabs.first else { return }
        let alert = NSAlert()
        alert.messageText = "Rename terminal"
        alert.informativeText = "Give it a name that says what it's working on. It's also shown as the tab's title in Terminal."
        let field = NSTextField(string: tab.customTitle.isEmpty ? window.name : tab.customTitle)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        bridge.setTitle(field.stringValue.trimmingCharacters(in: .whitespaces), windowID: window.id, tab: tab.index)
        refreshSoon()
    }

    func newWindow() {
        bridge.newWindow()
        refreshSoon()
    }

    func newWindowInFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Terminal Here"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        bridge.newWindow(in: url.path)
        refreshSoon()
    }

    func close(_ window: ManagedWindow) {
        bridge.close(windowID: window.id)
        refreshSoon()
    }

    var diagnostics: String {
        let header = "Terminal Manager diagnostics — \(Date())\nquiet=\(Settings.shared.quietSeconds)s accessDenied=\(accessDenied) terminalFrontmost=\(TerminalBridge.isTerminalFrontmost)"
        return ([header] + windows.map(\.diagnostics)).joined(separator: "\n")
    }

    func window(withID id: Int) -> ManagedWindow? {
        windows.first { $0.id == id }
    }

    // MARK: Notifications

    private func needsYou(_ window: ManagedWindow) {
        guard !window.isViewed else { return }
        Notifier.shared.post(for: window, title: "\(window.name) needs you", body: window.detail)
    }

    private func stateChanged(_ window: ManagedWindow, from old: ActivityState, to new: ActivityState) {
        if window.isViewed { return }
        switch new {
        case .done:
            Notifier.shared.post(for: window, title: "\(window.name) finished",
                                 body: "The command finished in \((window.directory as NSString).abbreviatingWithTildeInPath).")
        case .working:
            Notifier.shared.clear(for: window)
        default:
            break
        }
    }
}
