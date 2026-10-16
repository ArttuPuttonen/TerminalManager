import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = SessionStore()
    private var bar: TopBarPanel!
    private var statusItem: NSStatusItem!
    private var lastAttentionCount = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon; lives in the top bar + menu bar
        buildMainMenu()

        bar = TopBarPanel(store: store)
        store.barFrame = { [weak self] in self?.bar.frame }
        store.onTick = { [weak self] in self?.refresh() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        Notifier.shared.setUp()
        Notifier.shared.onOpen = { [weak self] id in
            guard let self, let session = self.store.session(withID: id) else { return }
            self.store.show(session)
        }

        store.restore()
        if store.sessions.isEmpty { store.newSession() }

        bar.orderFrontRegardless()
        refresh()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.bar.relayout() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.save()
        store.sessions.forEach { $0.terminate() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = store.sessions.filter { $0.state == .working || $0.state == .needsInput }
        guard !busy.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Terminal Manager?"
        alert.informativeText = "\(busy.count) terminal(s) still have programs running: "
            + busy.map(\.name).joined(separator: ", ") + ". They will be stopped."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    // MARK: Refresh

    private func refresh() {
        bar.relayout()
        let count = store.attentionCount
        guard count != lastAttentionCount, let button = statusItem.button else { return }
        lastAttentionCount = count
        button.image = NSImage(systemSymbolName: count > 0 ? "terminal.fill" : "terminal",
                               accessibilityDescription: "Terminal Manager")
        button.imagePosition = .imageLeading
        if count > 0 {
            button.attributedTitle = NSAttributedString(
                string: " \(count)",
                attributes: [.foregroundColor: NSColor.systemOrange,
                             .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)]
            )
        } else {
            button.title = ""
        }
    }

    // MARK: Menu bar menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if store.sessions.isEmpty {
            menu.addItem(NSMenuItem(title: "No terminals", action: nil, keyEquivalent: ""))
        }
        for session in store.sessions {
            let item = NSMenuItem(title: "\(session.name) — \(session.state.label)",
                                  action: #selector(showSession(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = session
            item.image = Self.dot(color: NSColor(session.state.color))
            item.toolTip = session.detail
            menu.addItem(item)
        }

        menu.addItem(.separator())
        add(to: menu, "Go to Next Terminal That Needs You", #selector(nextAttention))
        add(to: menu, "New Terminal", #selector(newTerminal))
        add(to: menu, "New Terminal in Folder…", #selector(newTerminalInFolder))
        add(to: menu, "Hide All Terminals", #selector(hideAll))
        add(to: menu, bar.isVisible ? "Hide Top Bar" : "Show Top Bar", #selector(toggleBar))

        menu.addItem(.separator())
        let settings = Settings.shared
        add(to: menu, "Auto-hide When Working Again", #selector(toggleAutoHide), on: settings.autoHide)
        add(to: menu, "Notifications", #selector(toggleNotifications), on: settings.notifications)
        add(to: menu, "Sounds", #selector(toggleSound), on: settings.sound)
        add(to: menu, "Reopen Terminals at Launch", #selector(toggleRestore), on: settings.restoreSessions)

        let quietItem = NSMenuItem(title: "“Needs You” After Silence Of", action: nil, keyEquivalent: "")
        let quietMenu = NSMenu()
        for seconds in [2.0, 3.0, 4.0, 6.0, 10.0, 20.0] {
            let item = NSMenuItem(title: "\(Int(seconds)) seconds", action: #selector(setQuiet(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.state = settings.quietSeconds == seconds ? .on : .off
            quietMenu.addItem(item)
        }
        quietItem.submenu = quietMenu
        menu.addItem(quietItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Terminal Manager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func add(to menu: NSMenu, _ title: String, _ action: Selector, on: Bool? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let on { item.state = on ? .on : .off }
        menu.addItem(item)
    }

    private static func dot(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return image
    }

    @objc private func showSession(_ sender: NSMenuItem) {
        if let session = sender.representedObject as? TerminalSession { store.show(session) }
    }
    @objc private func nextAttention() { store.showNextNeedingAttention() }
    @objc func newTerminal() { store.newSession() }
    @objc func newTerminalInFolder() { store.newSessionInFolder() }
    @objc private func hideAll() { store.hideAll() }
    @objc private func toggleBar() {
        if bar.isVisible { bar.orderOut(nil) } else { bar.orderFrontRegardless() }
    }
    @objc private func toggleAutoHide() { Settings.shared.autoHide.toggle() }
    @objc private func toggleNotifications() { Settings.shared.notifications.toggle() }
    @objc private func toggleSound() { Settings.shared.sound.toggle() }
    @objc private func toggleRestore() { Settings.shared.restoreSessions.toggle() }
    @objc private func setQuiet(_ sender: NSMenuItem) {
        if let seconds = sender.representedObject as? Double { Settings.shared.quietSeconds = seconds }
    }

    // MARK: Main menu (keyboard shortcuts + copy/paste while a terminal is focused)

    @objc private func closeTerminalWindow() {
        NSApp.keyWindow?.orderOut(nil)
    }

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Terminal Manager", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Terminal Manager", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Terminal Manager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "Shell")
        let newItem = fileMenu.addItem(withTitle: "New Terminal", action: #selector(newTerminal), keyEquivalent: "t")
        newItem.target = self
        let folderItem = fileMenu.addItem(withTitle: "New Terminal in Folder…", action: #selector(newTerminalInFolder), keyEquivalent: "T")
        folderItem.target = self
        let closeItem = fileMenu.addItem(withTitle: "Hide Terminal", action: #selector(closeTerminalWindow), keyEquivalent: "w")
        closeItem.target = self
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}
