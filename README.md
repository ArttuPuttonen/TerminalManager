# Terminal Manager

A small native macOS app that keeps all your terminals in a strip at the top of the screen,
so you don't end up with a pile of windows open. Each terminal is a pill:

| Color | Meaning |
|-------|---------|
| 🟢 green | **Working.** A program is running and making progress (output or CPU). Leave it alone. |
| 🟠 orange, pulsing | **Needs you.** The program went quiet, rang the bell or sent a notification. It is probably asking you something. |
| 🔵 blue | **Done.** A command that ran for a while finished and you haven't looked at it yet. |
| ⚪ gray | **Idle.** Shell prompt, nothing running. |

How it works:

1. Click a pill to open that terminal under the bar. Click it again (or press ⌘W, or the red close button) to hide it. Hiding never stops the terminal.
2. When a terminal needs you, its pill turns orange, you get a macOS notification and a sound, and the menu bar icon shows how many terminals are waiting. Click the notification to jump to the terminal.
3. Answer it. Once the program is working on its own again (and you've stopped typing for a couple of seconds), the window **hides itself**.
4. Right-click a pill to **rename** it ("API refactor", "deploy", ...), mark it **Keep Open** so it never auto-hides, or close it.

The menu bar icon has the list of terminals, "Go to Next Terminal That Needs You", and settings: auto-hide,
notifications, sounds, reopening terminals at launch, and how many seconds of silence count as "needs you".

Shortcuts while a terminal is focused: ⌘T new terminal, ⇧⌘T new terminal in a folder, ⌘W hide, ⌘C/⌘V copy/paste.

## How "needs you" is detected

The app runs the shells itself (using [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)), so it can look at each terminal's pty:

- If only the shell is in the foreground, the terminal is **idle**. If a command just finished after running for more than 5 seconds while you weren't looking, it's **done**.
- If a program is in the foreground and it printed something recently or is using CPU, it is **working**.
- If it has been silent for the configured time (default 4 s) and isn't using CPU, or it rang the terminal bell / sent an OSC 9/777 notification, it **needs you**.

This works well with Claude Code: its spinner keeps printing while it works and stops when it asks for permission or finishes a turn. For faster, more reliable alerts, set Claude Code's notification channel to the terminal bell (`/config` → Notifications → terminal bell). The app then flags the terminal right away.

A long, silent, low-CPU command (like `sleep 60`) will also show as "needs you". If that happens a lot, raise the silence threshold in the menu.

## Build and run

You need macOS 14+ and Xcode 26 (Swift 6.2). SwiftTerm requires it.

```bash
git clone https://github.com/arttuputtonen/terminalmanager.git
cd terminalmanager
./scripts/build-app.sh
cp -R "build/Terminal Manager.app" /Applications/
open "/Applications/Terminal Manager.app"
```

Allow notifications when macOS asks. To start it at login: System Settings → General → Login Items → add Terminal Manager.

For development you can also `swift run`. Notifications are turned off in that mode because macOS only allows them for apps inside an `.app` bundle.

Every push is also built by GitHub Actions, which uploads a zipped app as a build artifact. A downloaded build is unsigned, so clear the quarantine flag before opening it:
`xattr -dr com.apple.quarantine "Terminal Manager.app"`.

## Code layout

- `Sources/TerminalManager/TerminalSession.swift`: one terminal: shell process, window, and the state detection.
- `Sources/TerminalManager/ProcessInspector.swift`: finds the foreground job, its CPU time and working directory.
- `Sources/TerminalManager/SessionStore.swift`: all terminals, polling, notifications, and auto-hide.
- `Sources/TerminalManager/TopBar.swift`: the floating bar and the pills (SwiftUI).
- `Sources/TerminalManager/AppDelegate.swift`: menu bar icon, menus, and app lifecycle.
