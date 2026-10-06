import AppKit

enum FinderRevealer {
    struct Failure: Error {
        let code: Int
        let message: String
        var isPermissionDenied: Bool { code == -1743 }
    }

    /// Compiled once. Paths are passed as Apple event parameters, never spliced into the
    /// source, so no file name can change what the script does.
    private static let script: NSAppleScript? = {
        let source = """
        on revealItem(itemPath, parentPath, enterFolder)
            set theItem to (POSIX file itemPath) as alias
            if parentPath is "" then
                set theParent to missing value
            else
                set theParent to (POSIX file parentPath) as alias
            end if
            tell application "Finder"
                if (count of Finder windows) is 0 then
                    set w to make new Finder window
                else
                    set w to Finder window 1
                end if
                try
                    set collapsed of w to false
                end try
                if enterFolder or theParent is missing value then
                    set target of w to theItem
                else
                    set target of w to theParent
                    reveal theItem
                    select theItem
                end if
                set index of w to 1
                activate
            end tell
        end revealItem
        """
        let s = NSAppleScript(source: source)
        var error: NSDictionary?
        guard s?.compileAndReturnError(&error) == true else {
            NSLog("GoTo: reveal script failed to compile: \(error ?? [:])")
            return nil
        }
        return s
    }()

    static var scriptCompiles: Bool { script != nil }

    private static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    /// Selects `path` in the most recently used Finder window (or a new one if none are open)
    /// and brings Finder to the front. With `enterFolder`, a folder is opened instead of selected.
    @discardableResult
    static func reveal(_ path: String, enterFolder: Bool = false) -> Failure? {
        guard let script else { return Failure(code: -1, message: "The reveal script could not be compiled.") }
        var parent = (path as NSString).deletingLastPathComponent
        if path == "/" { parent = "" }

        var error: NSDictionary?
        callHandler("revealItem", in: script, with: [.init(string: path), .init(string: parent), .init(boolean: enterFolder)], error: &error)
        guard let error else { return nil }
        return Failure(code: error[NSAppleScript.errorNumber] as? Int ?? -1,
                       message: error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error")
    }

    /// Invokes an AppleScript handler with typed arguments (a kASSubroutineEvent).
    @discardableResult
    static func callHandler(_ name: String, in script: NSAppleScript, with args: [NSAppleEventDescriptor],
                            error: inout NSDictionary?) -> NSAppleEventDescriptor? {
        let params = NSAppleEventDescriptor.list()
        for (i, a) in args.enumerated() { params.insert(a, at: i + 1) }
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: fourCC("ascr"),           // kASAppleScriptSuite
                                                      eventID: fourCC("psbr"),                 // kASSubroutineEvent
                                                      targetDescriptor: .currentProcess(),
                                                      returnID: AEReturnID(kAutoGenerateReturnID),
                                                      transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: name.lowercased()), forKeyword: fourCC("snam")) // keyASSubroutineName
        event.setParam(params, forKeyword: keyDirectObject)
        return script.executeAppleEvent(event, error: &error)
    }

    static func presentError(_ failure: Failure, path: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        if failure.isPermissionDenied {
            alert.messageText = "Go To needs permission to control Finder"
            alert.informativeText = "Open System Settings › Privacy & Security › Automation and enable Finder under Go To."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        } else {
            alert.messageText = "Couldn’t reveal “\((path as NSString).lastPathComponent)”"
            alert.informativeText = "\(failure.message) (\(failure.code))"
            alert.runModal()
        }
    }
}
