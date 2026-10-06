import AppKit

#if GOTO_DEVTOOLS
// Developer build (build/goto-tools): icon rendering, search benchmarks and panel snapshots.
// These never ship in GoTo.app, which ignores its command-line arguments entirely.
DevTools.run(CommandLine.arguments)
#else
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
#endif
