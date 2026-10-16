# Terminal Manager

A small native macOS companion for the built-in **Terminal** app. Keep using Terminal as you
always have: as soon as you open your first Terminal window, a strip appears at the top of the
screen with one pill per window. When the last window closes, the strip goes away.

| Color | Meaning |
|-------|---------|
| 🟢 green dot | **Working.** A program is running and making progress (output or CPU). Leave it alone. |
| 🟠 orange, pinging | **Needs you.** The program went quiet. It is probably asking you something. |
| 🔵 blue | **Done.** A command that ran for a while finished and you haven't looked at it yet. |
| ⚪ gray ring | **Idle.** Shell prompt, nothing running. |

How it works:

1. Click a pill to bring that Terminal window to the front. Click it again to minimize it to the Dock.
2. When a terminal needs you, its pill turns orange, you get a macOS notification and a sound, and the menu bar icon shows how many are waiting. Click the notification to jump straight to that window.
3. Answer it. Once the program is working on its own again (and you've stopped typing for a couple of seconds), the window **minimizes itself**.
4. Right-click a pill to **rename** it (the name becomes the tab's title in Terminal too), mark it **Keep Open** so it never auto-minimizes, or close the window.

Pills are named after the folder the terminal is in, unless you rename them. A window with
several tabs shows the most urgent tab.

The menu bar icon has the list of windows, "Go to Next Terminal That Needs You", and settings:
auto-minimize, notifications, sounds, Open at Login, and how many seconds of silence count as "needs you".

## How "needs you" is detected

Terminal Manager asks Terminal (via AppleScript) which windows and tabs exist and which tty
each tab uses. Then, for each tab, it looks at the kernel's process table and at the tty device itself:

- If only the shell is in the foreground, the tab is **idle**. If a command just finished after running for more than 5 seconds while you weren't looking, it's **done**.
- If a program is in the foreground and it printed something recently or is using CPU, it is **working**. The kernel timestamps a tty on every write, so we can see output without reading it.
- If it has been silent for the configured time (default 4 s) and isn't using CPU, it **needs you**.

This works well with Claude Code: its spinner keeps printing while it works and stops when it
asks for permission or finishes a turn.

A long, silent, low-CPU command (like `sleep 60`) will also show as "needs you". If that happens
a lot, raise the silence threshold in the menu.

## Build and install

You need macOS 14+ and Xcode (or the Command Line Tools).

```bash
git clone https://github.com/ArttuPuttonen/TerminalManager.git
cd TerminalManager
./scripts/build-app.sh
cp -R "build/Terminal Manager.app" /Applications/
open "/Applications/Terminal Manager.app"
```

The first time it runs:

- It turns on **Open at Login**, so it's always ready in the background (you can switch this off in its menu).
- macOS asks whether Terminal Manager may **control Terminal**. Click OK. If you clicked Don't Allow, use the menu's "Allow Access to Terminal…" (System Settings → Privacy & Security → Automation).
- macOS asks to allow **notifications**.

Nothing appears until you open a Terminal window. A small terminal icon stays in the menu bar for settings and Quit.

Because the app is signed ad hoc, macOS may ask for the Terminal permission again after you rebuild it.

Every push is also built by GitHub Actions, which uploads a zipped app as a build artifact. A downloaded build is unsigned, so clear the quarantine flag before opening it:
`xattr -dr com.apple.quarantine "Terminal Manager.app"`.

## Code layout

- `Sources/TerminalManager/TerminalBridge.swift`: AppleScript bridge that lists, shows, minimizes and renames Terminal windows.
- `Sources/TerminalManager/TerminalWindow.swift`: one Terminal window, its tabs, and the state detection.
- `Sources/TerminalManager/ProcessInspector.swift`: processes on a tty, tty activity times, CPU time and working directory.
- `Sources/TerminalManager/SessionStore.swift`: polling, notifications, and auto-minimize.
- `Sources/TerminalManager/TopBar.swift`: the floating bar and the pills (SwiftUI).
- `Sources/TerminalManager/AppDelegate.swift`: menu bar icon, menus, and app lifecycle.
