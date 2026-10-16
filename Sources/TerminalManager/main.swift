import AppKit

// Started by a Claude Code hook: record the status and exit, without starting the app.
let arguments = CommandLine.arguments
if arguments.count >= 3, arguments[1] == ClaudeHooks.hookFlag {
    ClaudeHooks.runHook(event: arguments[2])
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}
