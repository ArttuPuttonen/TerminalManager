# Terminal Manager

A small native macOS companion for the built-in **Terminal** app. Keep using Terminal as you
always have: as soon as you open your first Terminal window, a strip appears at the top of the
screen. When the last window closes, the strip goes away.

To stay out of the way of your browser's tabs, the strip normally collapses to a small row of
colored dots under the notch, one per window. Hover over it (or click it) to expand it into
full pills with names; move away and it shrinks back.

| Color | Meaning |
|-------|---------|
| 🔵 blue | **Working.** Leave it alone. |
| 🟠 orange, pinging | **Needs you.** Claude is asking for permission, asking a question, or wants a plan approved. |
| 🟢 green | **Done.** It finished something you haven't seen yet. Stays green while you look at it, and turns gray once you've seen it and moved on (hid it or switched away). |
| ⚪ gray | **Idle.** Nothing going on, nothing pending. |

How it works:

1. Click a pill to bring that Terminal window to the front. Click it again to hide it. Hidden windows live in the bar, not in the Dock, so your desktop and Dock stay clean.
2. When a terminal needs you, its pill turns orange, you get a macOS notification and a sound, and the menu bar icon shows how many are waiting. Click the notification to jump straight to that window.
3. Answer it, then click the pill again (or the yellow button) to put the window away. If you'd rather have windows hide by themselves once the program is working again, turn on "Auto-Hide When Working Again" in the menu (off by default).
4. Opening a terminal from its pill hides the other open ones into the bar, so only one is on screen at a time ("One Terminal at a Time" in the menu; windows marked Keep Open stay).
5. Right-click a pill to **rename** it (the name becomes the tab's title in Terminal too), mark it **Keep Open** so it never auto-hides, or close the window.

If you minimize a window the usual way (yellow button or ⌘M), Terminal Manager tries to take it
out of the Dock by making it invisible while it stays minimized, so nothing flashes. If macOS keeps
it in the Dock anyway, it just stays there; its pill works either way. You can turn this off in the menu.
Clicking a pill always hides a window without touching the Dock. When Terminal Manager quits, windows hidden in the bar go back to the Dock so they are never lost.

The **+** at the end of the bar opens a new Terminal window (right-click it to pick a folder first).
It only shows while you have at least one Terminal window open.

Pills are named after the folder the terminal is in, unless you rename them. A window with
several tabs shows the most urgent tab.

The menu bar icon has the list of windows, "Go to Next Terminal That Needs You", and settings:
auto-hide, minimized windows to the bar, notifications, sounds, Open at Login, and how many seconds of silence count as "needs you".

## How the status is known

**Claude Code (exact).** Choose **Connect Claude Code for Exact Status…** in the menu bar menu.
This adds hooks to `~/.claude/settings.json` (your other settings and hooks are kept, and a backup
is saved as `settings.json.terminalmanager-backup`). Claude Code then reports each session's status itself:

| Claude Code event | Status |
|---|---|
| You send a prompt, it runs tools | Working |
| It asks for permission, uses AskUserQuestion, or presents a plan | Needs you (chime) |
| It finishes its turn | Done (chime), gray once you've seen it and moved on |

It applies to Claude sessions started after connecting. Disconnect from the same menu.

**Everything else (a guess).** Terminal Manager asks Terminal (via AppleScript) which windows and tabs
exist and which tty each uses, then looks at the kernel's process table and the tty device itself:

- Only the shell in the foreground: **idle**. A command that ran for more than 5 seconds and finished while you weren't looking: **done**.
- A program printing output or using CPU: **working**. The kernel timestamps a tty on every write, so we can see output without reading it.
- A program that goes quiet after at least 5 seconds of work: **done**. Without hooks there's no way to tell "finished" from "asking you something", so a guess never shows orange.

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
- macOS asks whether Terminal Manager may **control Terminal** (needed to list, show and hide its windows). Click OK. If you clicked Don't Allow, use the menu's "Allow Access to Terminal…" (System Settings → Privacy & Security → Automation).
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
