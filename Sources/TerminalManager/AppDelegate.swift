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
        store.onTick = { [weak self] in self?.refresh() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        Notifier.shared.setUp()
        Notifier.shared.onOpen = { [weak self] id in
            guard let self, let window = self.store.window(withID: id) else { return }
            self.store.show(window)
        }
        Permissions.setUpLoginItemOnce()
        ClaudeHooks.refreshIfConnectedElsewhere()
        refresh()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.bar.relayout(animated: false) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.returnHiddenWindowsToDock()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

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

        if store.accessDenied {
            add(to: menu, "Allow Access to Terminal…", #selector(openAutomationSettings))
            menu.addItem(.separator())
        }
        if store.windows.isEmpty {
            let empty = NSMenuItem(title: "No Terminal windows open", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for window in store.windows {
            let item = NSMenuItem(title: "\(window.name) — \(window.state.label)",
                                  action: #selector(showWindow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = window
            item.image = Self.dot(color: NSColor(window.state.color))
            item.toolTip = window.detail
            menu.addItem(item)
        }

        menu.addItem(.separator())
        add(to: menu, "New Terminal Window", #selector(newWindow))
        add(to: menu, "New Terminal Window in Folder…", #selector(newWindowInFolder))
        add(to: menu, "Go to Next Terminal That Needs You", #selector(nextAttention))
        add(to: menu, "Hide All Terminals", #selector(hideAll))
        add(to: menu, bar.userHidden ? "Show Top Bar" : "Hide Top Bar", #selector(toggleBar))

        menu.addItem(.separator())
        if ClaudeHooks.isConnected {
            add(to: menu, "Claude Code Connected (Exact Status)", #selector(disconnectClaude), on: true)
        } else {
            add(to: menu, "Connect Claude Code for Exact Status…", #selector(connectClaude))
        }

        menu.addItem(.separator())
        let settings = Settings.shared
        add(to: menu, "Auto-Hide When Working Again", #selector(toggleAutoHide), on: settings.autoHide)
        add(to: menu, "Take Minimized Windows Out of the Dock", #selector(toggleKeepInBar), on: settings.keepMinimizedInBar)
        add(to: menu, "Notifications", #selector(toggleNotifications), on: settings.notifications)
        add(to: menu, "Sounds", #selector(toggleSound), on: settings.sound)
        add(to: menu, "Open at Login", #selector(toggleLogin), on: Permissions.opensAtLogin)

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
        add(to: menu, "Copy Diagnostics", #selector(copyDiagnostics))
        menu.addItem(NSMenuItem(title: "Quit Terminal Manager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func add(to menu: NSMenu, _ title: String, _ action: Selector, on: Bool? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let on { item.state = on ? .on : .off }
        menu.addItem(item)
    }

    private static func dot(color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    @objc private func showWindow(_ sender: NSMenuItem) {
        if let window = sender.representedObject as? ManagedWindow { store.show(window) }
    }
    @objc private func nextAttention() { store.showNextNeedingAttention() }
    @objc private func hideAll() { store.hideAll() }

    @objc private func connectClaude() {
        let alert = NSAlert()
        alert.messageText = "Connect Claude Code?"
        alert.informativeText = """
        Claude Code will tell Terminal Manager exactly when it's working, when it asks you something         (permission, a question, a plan to approve) and when it's done, so pills are never guessed.

        This adds a few hooks to ~/.claude/settings.json that run Terminal Manager for a moment.         Your other settings and hooks stay as they are, and a backup is saved next to the file.         It takes effect for Claude sessions started from now on. You can disconnect any time from this menu.
        """
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try ClaudeHooks.connect()
        } catch {
            showError("Couldn't update ~/.claude/settings.json", error)
        }
    }

    @objc private func disconnectClaude() {
        do {
            try ClaudeHooks.disconnect()
        } catch {
            showError("Couldn't update ~/.claude/settings.json", error)
        }
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }
    @objc private func newWindow() { store.newWindow() }
    @objc private func newWindowInFolder() { store.newWindowInFolder() }
    @objc private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.diagnostics, forType: .string)
    }
    @objc private func toggleKeepInBar() { Settings.shared.keepMinimizedInBar.toggle() }
    @objc private func toggleBar() { bar.userHidden.toggle() }
    @objc private func openAutomationSettings() { Permissions.openAutomationSettings() }
    @objc private func toggleAutoHide() { Settings.shared.autoHide.toggle() }
    @objc private func toggleNotifications() { Settings.shared.notifications.toggle() }
    @objc private func toggleSound() { Settings.shared.sound.toggle() }
    @objc private func toggleLogin() { Permissions.setOpensAtLogin(!Permissions.opensAtLogin) }
    @objc private func setQuiet(_ sender: NSMenuItem) {
        if let seconds = sender.representedObject as? Double { Settings.shared.quietSeconds = seconds }
    }

    // MARK: Main menu (only so copy/paste work in the Rename dialog)

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Terminal Manager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
